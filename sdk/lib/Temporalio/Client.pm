# ABOUTME: Temporal client (spec section 7): async connect over the callback
# ABOUTME: bridge, holding the connection, namespace, identity, and converter.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future::AsyncAwait;
use Scalar::Util ();
use Sys::Hostname ();
use Temporalio::Converter::Data;
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Client::Connection ();
use Temporalio::Client::KeepAliveConfig ();
use Temporalio::Client::RetryConfig ();
use Temporalio::Client::TlsConfig ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Client::WorkflowExecutionIterator ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::RpcError ();
use Temporalio::Runtime ();
use Temporalio::SDK ();

class Temporalio::Client {
    # TemporalCoreRpcService discriminator values (header lines 8-14:
    # Workflow=1, Operator, Cloud, Test, Health).
    my %RPC_SERVICE = (
        workflow => 1,
        operator => 2,
        cloud    => 3,
        test     => 4,
        health   => 5,
    );

    # Workflow-id reuse/conflict policy spec strings -> proto enum numbers.
    # MUST match temporal.api.enums.v1.WorkflowId{Reuse,Conflict}Policy
    # (introspected from the vendored proto; cross-checked against sdk-python
    # temporalio/common.py WorkflowIDReusePolicy / WorkflowIDConflictPolicy).
    my %ID_REUSE_POLICY = (
        unspecified                 => 0,
        allow_duplicate             => 1,
        allow_duplicate_failed_only => 2,
        reject_duplicate            => 3,
        terminate_if_running        => 4,
    );
    my %ID_CONFLICT_POLICY = (
        unspecified        => 0,
        fail               => 1,
        use_existing       => 2,
        terminate_existing => 3,
    );

    field $connection     :param;    # Temporalio::Client::Connection
    field $namespace      :param;
    field $identity       :param;
    field $data_converter :param;
    field $runtime        :param;

    method connection     { $connection }
    method namespace      { $namespace }
    method identity       { $identity }
    method data_converter { $data_converter }
    method runtime        { $runtime }

    # Rotation is manual and explicit (spec section 7.3): no refresh timer,
    # no refresh-on-UNAUTHENTICATED. Synchronous, no RPC.
    method update_api_key ($api_key) {
        $connection->update_api_key($api_key);
        return;
    }

    # get_workflow_handle($workflow_id, run_id => ..., first_execution_run_id
    # => ...) — returns a Temporalio::Client::WorkflowHandle without an RPC
    # (spec section 7.4).
    method get_workflow_handle ($workflow_id, %opts) {
        Temporalio::Exception::Argument->throw(
            message => 'get_workflow_handle requires a workflow id')
            unless defined $workflow_id && length $workflow_id;
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $opts{run_id},
            first_execution_run_id => $opts{first_execution_run_id},
        );
    }

    # start_workflow($workflow_or_string, \@args, %kwargs) — async (spec
    # section 7.4). Builds the StartWorkflowExecutionRequest, issues it over
    # _rpc_call (ALREADY_EXISTS special-cased to WorkflowAlreadyStarted via
    # the spec section 7.5 mapping), and returns a WorkflowHandle whose run_id
    # is the response's first run id.
    async method start_workflow ($workflow, $args = [], %kwargs) {
        my $request = await $self->_build_start_workflow_request(
            $workflow, $args, %kwargs);
        my $workflow_id = $request->workflow_id;
        my $response = await $self->_rpc_call(
            'StartWorkflowExecution', $request,
            error_context => {
                workflow_id   => $workflow_id,
                workflow_type => $request->workflow_type->name,
            });
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $response->run_id,
            first_execution_run_id => $response->run_id,
        );
    }

    # execute_workflow(...) — convenience: start then await result. result()
    # lands in P1.11; the helper is wired here for completeness once it does.
    async method execute_workflow ($workflow, $args = [], %kwargs) {
        my $handle = await $self->start_workflow($workflow, $args, %kwargs);
        return await $handle->result;
    }

    # signal_with_start_workflow($workflow_or_string, \@args, %kwargs) — async
    # (spec section 7.4). Same kwargs as start_workflow plus signal =>
    # $name, signal_args => \@args.
    async method signal_with_start_workflow ($workflow, $args = [], %kwargs) {
        my $request = await $self->_build_signal_with_start_workflow_request(
            $workflow, $args, %kwargs);
        my $workflow_id = $request->workflow_id;
        my $response = await $self->_rpc_call(
            'SignalWithStartWorkflowExecution', $request,
            error_context => {
                workflow_id   => $workflow_id,
                workflow_type => $request->workflow_type->name,
            });
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $response->run_id,
            first_execution_run_id => $response->run_id,
        );
    }

    # list_workflows($query, page_size => 100) — returns an async iterator
    # yielding WorkflowExecutionInfo records page-by-page (spec section 7.4;
    # sdk-python _impl.py list_workflows 391-394). No RPC until the first
    # ->next is awaited.
    method list_workflows ($query = undef, %opts) {
        return Temporalio::Client::_WorkflowExecutionIterator->new(
            client    => $self,
            query     => $query,
            page_size => $opts{page_size},
        );
    }

    # count_workflows($query) — async; returns { count => N, groups => [...] }
    # (spec section 7.4; sdk-python _impl.py count_workflows 396-409).
    async method count_workflows ($query = undef, %opts) {
        my $request = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.CountWorkflowExecutionsRequest')
            ->new({
                namespace => $namespace,
                query     => $query // '',
            });
        my $response =
            await $self->_rpc_call('CountWorkflowExecutions', $request);
        my $groups = $response->groups;
        return {
            count  => $response->count // 0,
            groups => [ defined $groups ? @$groups : () ],
        };
    }

    # _build_start_workflow_request($workflow_or_string, \@args, %kwargs) —
    # async; maps the spec section 7.4 kwargs onto a
    # StartWorkflowExecutionRequest. Validation (required id/task_queue, policy
    # strings) happens here, before any RPC. Args/memo/header values encode
    # through the data converter.
    async method _build_start_workflow_request ($workflow, $args, %kwargs) {
        my $class = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.StartWorkflowExecutionRequest');
        return await $self->_populate_start_request($class, $workflow, $args,
            \%kwargs);
    }

    # _build_signal_with_start_workflow_request(...) — async; like the above
    # but targets SignalWithStartWorkflowExecutionRequest and additionally
    # carries the signal name + encoded signal args.
    async method _build_signal_with_start_workflow_request ($workflow, $args, %kwargs) {
        my $signal      = delete $kwargs{signal};
        my $signal_args = delete $kwargs{signal_args} // [];
        Temporalio::Exception::Argument->throw(
            message => 'signal_with_start_workflow requires a signal name')
            unless defined $signal && length $signal;

        # The generated proto accessors are read-only, so every field must be
        # passed through new(): collect the signal extras and hand them to the
        # shared populator to merge into the constructor args.
        my %extra = (signal_name => $signal);
        if (@$signal_args) {
            my @payloads = await $data_converter->to_payloads($signal_args);
            my $Payloads = Temporalio::Core::Proto::resolve(
                'temporal.api.common.v1.Payloads');
            $extra{signal_input} = $Payloads->new({ payloads => [@payloads] });
        }

        my $class = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.SignalWithStartWorkflowExecutionRequest');
        return await $self->_populate_start_request($class, $workflow,
            $args, \%kwargs, \%extra);
    }

    # Shared body for both request kinds. Mutates and returns a fresh request
    # message of $class. Async because args/memo/header encode through the
    # data converter.
    async method _populate_start_request ($class, $workflow, $args, $kwargs, $extra = {}) {
        my %k = %$kwargs;
        my $id         = delete $k{id};
        my $task_queue = delete $k{task_queue};
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires an id')
            unless defined $id && length $id;
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires a task_queue')
            unless defined $task_queue && length $task_queue;

        my $workflow_name = _workflow_name($workflow);

        my $reuse = _policy_enum('id_reuse_policy', delete $k{id_reuse_policy},
            \%ID_REUSE_POLICY);
        my $conflict = _policy_enum('id_conflict_policy',
            delete $k{id_conflict_policy}, \%ID_CONFLICT_POLICY);

        my $WorkflowType = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.WorkflowType');
        my $TaskQueue = Temporalio::Core::Proto::resolve(
            'temporal.api.taskqueue.v1.TaskQueue');

        my %fields = (
            namespace                   => $namespace,
            workflow_id                 => $id,
            workflow_type               => $WorkflowType->new({ name => $workflow_name }),
            task_queue                  => $TaskQueue->new({ name => $task_queue }),
            identity                    => $identity,
            request_id                  => _new_uuid(),
            workflow_id_reuse_policy    => $reuse,
            workflow_id_conflict_policy => $conflict,
        );

        if (defined(my $cron = delete $k{cron_schedule})) {
            $fields{cron_schedule} = $cron;
        }
        if (delete $k{request_eager_start}) {
            $fields{request_eager_execution} = 1;
        }

        for my $pair (
            [ execution_timeout => 'workflow_execution_timeout' ],
            [ run_timeout       => 'workflow_run_timeout' ],
            [ task_timeout      => 'workflow_task_timeout' ],
            [ start_delay       => 'workflow_start_delay' ],
        ) {
            my ($kw, $proto_field) = @$pair;
            my $seconds = delete $k{$kw};
            $fields{$proto_field} = _duration($seconds) if defined $seconds;
        }

        if (my $args_ref = $args) {
            if (@$args_ref) {
                my @payloads = await $data_converter->to_payloads($args_ref);
                my $Payloads = Temporalio::Core::Proto::resolve(
                    'temporal.api.common.v1.Payloads');
                $fields{input} = $Payloads->new({ payloads => [@payloads] });
            }
        }

        if (defined(my $retry_policy = delete $k{retry_policy})) {
            $fields{retry_policy} = $retry_policy->to_proto;
        }
        if (defined(my $priority = delete $k{priority})) {
            $fields{priority} = $priority->to_proto;
        }
        if (defined(my $sa = delete $k{search_attributes})) {
            $fields{search_attributes} = _coerce_search_attributes($sa);
        }
        if (defined(my $memo = delete $k{memo})) {
            $fields{memo} = await $self->_encode_string_payload_map(
                'temporal.api.common.v1.Memo', $memo);
        }
        if (defined(my $headers = delete $k{headers})) {
            $fields{header} = await $self->_encode_string_payload_map(
                'temporal.api.common.v1.Header', $headers);
        }

        # Quietly ignore fields parked for later phases (static_summary/
        # static_details/versioning_override) — but reject genuine typos.
        delete @k{qw(static_summary static_details versioning_override)};
        if (my @unknown = sort keys %k) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown start_workflow option(s): '
                         . join(', ', @unknown));
        }

        # Merge caller-supplied extras (e.g. signal_name/signal_input for the
        # SignalWithStart variant) — the generated proto accessors are
        # read-only, so everything must arrive via new().
        %fields = (%fields, %$extra);

        return $class->new(\%fields);
    }

    # Encode a { name => value } hashref into a temporal.api.common.v1.{Memo,
    # Header} message: each value becomes a single Payload via the data
    # converter, keyed by name in the proto's `fields` map.
    async method _encode_string_payload_map ($proto_name, $hashref) {
        my $Message = Temporalio::Core::Proto::resolve($proto_name);
        my %map;
        for my $key (sort keys %$hashref) {
            my ($payload) = await $data_converter->to_payloads([ $hashref->{$key} ]);
            $map{$key} = $payload;
        }
        return $Message->new({ fields => \%map });
    }

    # ----- non-method helpers (file-scope subs compile into main:: under a
    # bare `class`; keep them here so the methods above can call them) -----

    sub _workflow_name ($workflow) {
        # A workflow function ref carries its registered name elsewhere
        # (P3.1); v0.1's client takes the type name as a string. A coderef is
        # not yet resolvable, so require a non-empty string here.
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires a workflow type name (string)')
            unless defined $workflow && !ref $workflow && length $workflow;
        return $workflow;
    }

    sub _policy_enum ($name, $value, $table) {
        return 0 unless defined $value;          # unspecified
        return $value if $value =~ /\A[0-9]+\z/; # already a proto number
        my $num = $table->{$value};
        Temporalio::Exception::Argument->throw(
            message => "invalid $name '$value' (expected one of "
                     . join(', ', sort keys %$table) . ')')
            unless defined $num;
        return $num;
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve(
            'google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }

    sub _coerce_search_attributes ($sa) {
        return $sa->to_proto
            if Scalar::Util::blessed($sa)
            && $sa->isa('Temporalio::Common::TypedSearchAttributes');
        # A bare untyped hashref is forbidden (spec section 7.4 — no guessing).
        Temporalio::Exception::Argument->throw(
            message => 'search_attributes must be a '
                     . 'Temporalio::Common::TypedSearchAttributes instance '
                     . '(a bare untyped hashref is not accepted — spec 7.4)');
    }

    # Detect Data::UUID once at load time, NOT lazily on first call: the first
    # _new_uuid call now happens inside an async (Future::AsyncAwait) frame
    # (WorkflowHandle->cancel/signal), and a failed `require` there leaves $@
    # set in a way the async error-detection re-raises. `local $@` keeps the
    # probe self-contained regardless.
    my $HAVE_DATA_UUID = do { local $@; eval { require Data::UUID; 1 } ? 1 : 0 };

    # A v4-ish UUID for request_id. The server treats request_id as an opaque
    # idempotency token; any unique value works. Uses Data::UUID if present,
    # else a random fallback in canonical 8-4-4-4-12 form.
    sub _new_uuid () {
        my $have_uuid = $HAVE_DATA_UUID;
        if ($have_uuid) {
            return lc(Data::UUID->new->create_str);
        }
        my @h = map { sprintf '%04x', int(rand(0x10000)) } 1 .. 8;
        return sprintf '%s%s-%s-4%s-%x%s-%s%s%s',
            $h[0], $h[1], $h[2], substr($h[3], 1),
            (8 + int(rand(4))), substr($h[4], 1), $h[5], $h[6], $h[7];
    }

    # _rpc_call($rpc_name, $request_msg, %opts) — async. The single funnel
    # every client method's RPC goes through (spec section 7.5): encodes the
    # request proto, calls temporal_core_client_rpc_call over the callback
    # bridge, decodes the typed response, and maps failures onto the
    # exception hierarchy via Temporalio::Core::Callback::rpc_error_for.
    #
    # %opts:
    #   service        => workflow|operator|cloud|test|health (default workflow)
    #   retry          => boolean (default 1 — every high-level client method
    #                     sets retry, and core applies the client RetryConfig;
    #                     pass 0 for a raw single-shot call)
    #   timeout        => seconds (default 0 = no timeout)
    #   response_class => proto class (default: request class s/Request$/Response/)
    #   error_context  => hashref merged into the rpc_error_for arguments
    #                     (e.g. workflow_id/workflow_type for ALREADY_EXISTS)
    async method _rpc_call ($rpc, $request, %opts) {
        my $service        = delete $opts{service} // 'workflow';
        my $retry          = exists $opts{retry} ? !!delete $opts{retry} : 1;
        my $timeout        = delete $opts{timeout} // 0;
        my $response_class = delete $opts{response_class};
        my $error_context  = delete $opts{error_context} // {};

        if (my @unknown = sort keys %opts) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown _rpc_call option(s): '
                         . join(', ', @unknown));
        }
        my $service_code = $RPC_SERVICE{$service}
            // Temporalio::Exception::Argument->throw(
                message => "unknown RPC service '$service' (expected one of "
                         . join(', ', sort keys %RPC_SERVICE) . ')');
        Temporalio::Exception::Argument->throw(
            message => '_rpc_call requires a proto request message object')
            unless Scalar::Util::blessed($request) && $request->can('encode');
        $response_class //= ref($request) =~ s/Request\z/Response/r;
        Temporalio::Exception::Argument->throw(
            message => "cannot derive a response class for '" . ref($request)
                     . "'; pass response_class")
            unless $response_class ne ref($request)
                && $response_class->can('decode');

        # Build the TemporalCoreRpcCallOptions record. @keep and the record
        # itself are lexicals held across the await — per the header, the
        # options must live through the callback.
        my @keep;
        my ($rpc_data, $rpc_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $rpc);
        my ($req_data, $req_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $request->encode);
        my $options = Temporalio::Core::FFI::RpcCallOptions->new(
            service              => $service_code,
            rpc_data             => $rpc_data,
            rpc_size             => $rpc_size,
            req_data             => $req_data,
            req_size             => $req_size,
            retry                => $retry ? 1 : 0,
            metadata_data        => undef,
            metadata_size        => 0,
            binary_metadata_data => undef,
            binary_metadata_size => 0,
            timeout_millis       => int($timeout * 1000),
            cancellation_token   => undef,
        );

        # The rpc completion always resolves done (Callback.pm kind 4) with
        # the raw fields; "either success or failure_message are always
        # present" (header), so a defined failure_message IS the error case.
        my $completion = await Temporalio::Core::Callback->issue_async(
            $runtime, rpc => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::client_rpc_call(
                    $connection->ptr, $options, $user_data, $trampoline);
            });

        if (defined $completion->{failure_message}) {
            die Temporalio::Core::Callback::rpc_error_for(
                status_code => $completion->{status_code},
                message     => $completion->{failure_message},
                details     => $completion->{failure_details},
                rpc         => $rpc,
                %$error_context,
            );
        }
        return $response_class->decode($completion->{success} // '');
    }

    # Default client identity, "<pid>@<hostname>" (spec section 7.1;
    # convention verified against sdk-python service.py and sdk-ruby
    # client/connection.rb).
    sub default_identity ($class) {
        return $$ . '@' . Sys::Hostname::hostname();
    }

    # Coerce a config kwarg: undef/0 stays undef, a hashref becomes
    # $config_class->new(%$hashref), an instance passes through, anything
    # else raises Argument.
    sub _coerce_config ($name, $value, $config_class) {
        return undef unless $value;
        return $config_class->new if !ref $value;    # e.g. tls => 1
        return $config_class->new(%$value) if ref $value eq 'HASH';
        return $value
            if Scalar::Util::blessed($value) && $value->isa($config_class);
        Temporalio::Exception::Argument->throw(
            message => "$name must be a boolean, a hashref, or a"
                     . " $config_class instance");
    }

    # connect($target, %options) — async (spec section 7.1/7.3): validates
    # and builds everything synchronously (bad PEM and friends fail before
    # any RPC), then awaits temporal_core_client_connect via the callback
    # bridge and returns a connected client.
    async sub connect ($class, $target, %options) {
        my $runtime        = delete $options{runtime};
        my $namespace      = delete $options{namespace} // 'default';
        my $api_key        = delete $options{api_key};
        my $tls            = delete $options{tls};
        my $identity       = delete $options{identity}
                          // $class->default_identity;
        my $rpc_metadata   = delete $options{rpc_metadata};
        my $retry          = delete $options{retry};
        # Keep-alive defaults ON with the spec 7.2 defaults (matching the
        # reference SDKs); pass keep_alive => 0 to disable.
        my $keep_alive     = exists $options{keep_alive}
            ? delete $options{keep_alive}
            : {};
        my $data_converter = delete $options{data_converter}
                          // Temporalio::Converter::Data->new;
        my $lazy           = delete $options{lazy} // 0;

        if (my @unknown = sort keys %options) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown Temporalio::Client->connect option(s): '
                         . join(', ', @unknown));
        }
        Temporalio::Exception::Argument->throw(
            message => 'Temporalio::Client->connect requires a target'
                     . ' host:port')
            unless defined $target && length $target;
        Temporalio::Exception::Argument->throw(
            message => 'lazy client connections are not supported in v0.1')
            if $lazy;

        $runtime //= Temporalio::Runtime->default;
        my $tls_config =
            _coerce_config(tls => $tls, 'Temporalio::Client::TlsConfig');
        my $retry_config =
            _coerce_config(retry => $retry, 'Temporalio::Client::RetryConfig')
            // Temporalio::Client::RetryConfig->new;
        my $keep_alive_config = _coerce_config(
            keep_alive => $keep_alive, 'Temporalio::Client::KeepAliveConfig');

        # The bridge parses target_url as a URL; the scheme encodes the TLS
        # choice exactly as the reference SDKs do (sdk-python service.py).
        my $target_url = ($tls_config ? 'https' : 'http') . "://$target";

        # rpc_metadata entries are MetadataRef items, each "key\nvalue";
        # keys cannot contain newlines (per the header).
        my @metadata_entries;
        for my $key (sort keys %{ $rpc_metadata // {} }) {
            my $value = $rpc_metadata->{$key} // '';
            if ("$key$value" =~ /\n/) {
                Temporalio::Exception::Argument->throw(
                    message => 'rpc_metadata keys and values must not contain'
                             . " newlines (key '$key')");
            }
            push @metadata_entries, "$key\n$value";
        }

        # Build the TemporalCoreConnectionOptions record tree. @keep (and
        # the record itself, as a lexical across the await) must live until
        # the connect callback fires — client.rs: options must live through
        # the callback.
        my @keep;
        my sub ref_pair ($name, $value) {
            my ($data, $size) =
                Temporalio::Core::FFI::keep_buffer(\@keep, $value);
            return ("${name}_data" => $data, "${name}_size" => $size);
        }
        my ($metadata_data, $metadata_count) =
            Temporalio::Core::FFI::keep_byte_array_ref_array(
                \@keep, \@metadata_entries);

        my $options_record = Temporalio::Core::FFI::ConnectionOptions->new(
            ref_pair(target_url     => $target_url),
            ref_pair(client_name    => 'temporal-perl'),
            ref_pair(client_version => $Temporalio::SDK::VERSION),
            metadata_data        => $metadata_data,
            metadata_size        => $metadata_count,
            binary_metadata_data => undef,
            binary_metadata_size => 0,
            ref_pair(api_key  => $api_key),
            ref_pair(identity => $identity),
            tls_options        => $tls_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $tls_config->to_ffi(\@keep))
                : undef,
            retry_options      => Temporalio::Core::FFI::keep_record(
                \@keep, $retry_config->to_ffi(\@keep)),
            keep_alive_options => $keep_alive_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $keep_alive_config->to_ffi(\@keep))
                : undef,
            http_connect_proxy_options       => undef,
            grpc_override_callback           => undef,
            grpc_override_callback_user_data => undef,
            dns_load_balancing_options       => undef,
        );

        # Spec section 7.3 step 5: a non-null fail byte array (surfaced by
        # the callback layer as Exception::Bridge) becomes RpcError with
        # the decoded message.
        my $connection_ptr;
        try {
            $connection_ptr = await Temporalio::Core::Callback->issue_async(
                $runtime, connect => sub ($user_data, $trampoline) {
                    Temporalio::Core::FFI::client_connect(
                        $runtime->core_ptr, $options_record,
                        $user_data, $trampoline);
                });
        }
        catch ($error) {
            if (Scalar::Util::blessed($error)
                && $error->isa('Temporalio::Exception::Bridge'))
            {
                Temporalio::Exception::RpcError->throw(
                    message => $error->message);
            }
            die $error;
        }

        return $class->new(
            connection => Temporalio::Client::Connection->new(
                runtime => $runtime,
                ptr     => $connection_ptr,
            ),
            namespace      => $namespace,
            identity       => $identity,
            data_converter => $data_converter,
            runtime        => $runtime,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Client - client for a Temporal server

=head1 SYNOPSIS

    use Temporalio::Client;

    my $client = await Temporalio::Client->connect(
        'localhost:7233',                  # positional, required
        namespace    => 'default',
        api_key      => $token,            # rotate via update_api_key
        tls          => 1 | { ... } | Temporalio::Client::TlsConfig->new(...),
        identity     => "$$\@$hostname",   # default: "<pid>@<hostname>"
        rpc_metadata => { 'x-extra' => 'foo' },
        retry        => { ... } | Temporalio::Client::RetryConfig->new(...),
        keep_alive   => { interval => 30, timeout => 15 },
        data_converter => $converter,      # default Temporalio::Converter::Data->new
        runtime      => $rt,               # default Temporalio::Runtime->default
    );

    $client->update_api_key($new_token);

=head1 DESCRIPTION

The Temporal client (spec section 7). C<connect> is async: it resolves the
runtime, validates and builds the C<TemporalCoreConnectionOptions> tree
synchronously — TLS PEM material is detected (content vs path) and slurped
before the async call, so a bad PEM raises
L<Temporalio::Exception::Argument> before any RPC — then awaits
C<temporal_core_client_connect> through the callback bridge. On failure it
raises L<Temporalio::Exception::RpcError> with the decoded bridge message.
On success it returns a client holding the
L<Temporalio::Client::Connection>, namespace, identity, data converter,
and runtime.

C<tls>, C<retry>, and C<keep_alive> each accept a boolean, a hashref of
constructor arguments, or a config instance (L<Temporalio::Client::TlsConfig>,
L<Temporalio::Client::RetryConfig>, L<Temporalio::Client::KeepAliveConfig>).
Retry defaults match sdk-core exactly and retries run inside sdk-core, not
the Perl layer. Keep-alive defaults on (30s/15s); disable with
C<< keep_alive => 0 >>. C<update_api_key> rotates the bearer token on the
live connection synchronously; rotation is always manual (spec section
7.3). Lazy connections are deferred past v0.1.

Every client RPC funnels through the private C<_rpc_call> helper: it
encodes the request proto, calls C<temporal_core_client_rpc_call> over the
callback bridge with C<retry> set by default (retries run inside sdk-core
against the client retry config), decodes the typed response, and maps
failures onto the exception hierarchy via the spec section 7.5 MUST-match
table in L<Temporalio::Core::Callback>.

Workflow operations (C<start_workflow> and friends, spec section 7.4)
arrive in later plan steps.

=cut

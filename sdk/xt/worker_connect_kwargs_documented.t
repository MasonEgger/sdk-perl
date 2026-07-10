# ABOUTME: Author test (spec R66, finding A12): every kwarg accepted by
# ABOUTME: Worker->new and Client->connect is POD-documented with type+default.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();

my $lib = "$FindBin::Bin/../lib/Temporalio";

sub slurp ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    return readline $fh;
}

# The POD section for one =head2 heading: everything up to the next =head.
sub pod_section ($src, $heading) {
    my ($section) = $src =~ /^=head2 \Q$heading\E$(.*?)(?=^=head[12]\b|\z)/ms;
    return $section;
}

# The =item C<kwarg> entries in a section, each mapped to its body text.
sub documented_items ($section) {
    my %items;
    while ($section =~ /^=item C<(\w+)>\n(.*?)(?=^=item\b|^=back\b)/msg) {
        $items{$1} = $2;
    }
    return \%items;
}

# The durable cross-check (finding A12): the accepted-kwarg set is parsed
# from the source of truth (field :param declarations / the known-keys
# validator), so the NEXT undocumented option fails here too. Each POD entry
# must open with the "(type; default ...)" or "(type; required)" convention.
sub check_surface ($name, $accepted, $items) {
    T2->subtest("$name kwargs documented with type and default (R66)" => sub {
        for my $kwarg (sort @$accepted) {
            my $body = $items->{$kwarg};
            T2->ok(defined $body, "$kwarg has an =item entry");
            next unless defined $body;
            my ($paren) = $body =~ /^\s*\(([^)]+)\)/s;
            T2->ok(defined $paren,
                "$kwarg entry opens with a (type; default/required) note")
                or next;
            my ($type) = split /;/, $paren, 2;
            $type =~ s/^\s+|\s+$//g if defined $type;
            T2->ok(defined $type && length $type, "$kwarg entry states a type");
            T2->like($paren, qr/;\s*(?:default|required)/i,
                "$kwarg entry states a default (or required)");
        }
        # Reverse direction: a documented kwarg that is no longer accepted is
        # POD drift, catch it too.
        my %known = map { $_ => 1 } @$accepted;
        for my $documented (sort keys %$items) {
            T2->ok($known{$documented},
                "documented kwarg '$documented' is actually accepted");
        }
    });
    return;
}

# --- Worker->new: accepted kwargs are the class's field :param declarations.
my $worker_src = slurp("$lib/Worker.pm");
my @worker_accepted = $worker_src =~ /^\s*field\s+\$(\w+)\s+:param/mg;
T2->ok(scalar @worker_accepted >= 33,
    'parsed the Worker->new kwarg set from field :param declarations');

my $worker_section = pod_section($worker_src, 'new');
T2->ok(defined $worker_section, 'Worker.pm has a =head2 new POD section');
check_surface('Worker->new', \@worker_accepted,
    documented_items($worker_section // ''));

# --- Client->connect: accepted kwargs are the known-keys validator set.
my $client_src = slurp("$lib/Client.pm");
my ($known_keys) = $client_src =~ /
    assert_known_keys\(\s*
    'Temporalio::Client->connect',\s*\\%options,\s*
    \{(.*?)\}
/xs;
T2->ok(defined $known_keys,
    'parsed the connect kwarg set from its known-keys validator');
my @connect_accepted = ($known_keys // '') =~ /(\w+)\s*=>\s*1/g;
T2->ok(scalar @connect_accepted >= 12,
    'connect kwarg set has the expected size');

my $connect_section = pod_section($client_src, 'connect');
T2->ok(defined $connect_section, 'Client.pm has a =head2 connect POD section');
check_surface('Client->connect', \@connect_accepted,
    documented_items($connect_section // ''));

T2->done_testing;

# ABOUTME: Workflow class to be loaded via require at runtime
# Tests whether :Signal handler still fires after CHECK phase.
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class My::WF :isa(Temporalio::Workflow::Definition) {
    method late_signal :Signal('lateSig') ($x) { return "late($x)" }
}
1;

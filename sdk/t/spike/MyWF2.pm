# ABOUTME: Workflow class using the no-explicit-phase Signal handler
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class My::WF2 :isa(Temporalio::Workflow::Definition2) {
    method late_signal :Signal('lateSig2') ($x) { return "late2($x)" }
}
1;

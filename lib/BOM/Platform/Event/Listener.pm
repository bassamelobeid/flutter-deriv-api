package BOM::Platform::Event::Listener;

use strict;
use warnings;

use BOM::Platform::Event::Register;
use BOM::Platform::Event::Process;

=head1 NAME

BOM::Platform::Event::Listener - Listen to events

=head1 SYNOPSIS

    BOM::Platform::Event::Listener::run()

=head1 DESCRIPTION

This class runs periodically and get registered event and pass that to
Event::Process to process fetched event.

=cut

sub run {
    while (1) {
        run_once();
        sleep 30;
    }

    return;
}

sub run_once {
    my $event_to_be_processed = BOM::Platform::Event::Register::get();

    return undef unless $event_to_be_processed;

    BOM::Platform::Event::Process::process($event_to_be_processed);

    return undef;
}

1;

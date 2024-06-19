package BOM::User::Client::StatusActions;

=head1 NAME

BOM::User::Client::StatusActions - Module for triggering events if a status has been applied based on configuration

=head1 SYNOPSIS

This module provides functionality to trigger events based on the status code applied to a client.
The events are triggered based on the configuration, stored in perl-Business-Config/share/config/account/status_actions.yml.
The configuration is a hash of status codes, with each status code having a list of actions to be triggered.
Where each action is a hash with the following
    - name: The name of the event to be triggered (this should be defined in BOM::Events)
    - default_args: The default arguments to be passed to the event

You can use this module by calling the trigger method as shown below:
    
    BOM::User::Client::StatusActions->trigger(
        $client_loginid,
        $status_code,
        $additional_args
        );

=head1 DESCRIPTION

This module is used by the `sync_siblings_data.pl` script. Meant to provide a testable
collection of subroutines.


=cut

use strict;
use warnings;

use Business::Config::Account;
use BOM::Platform::Event::Emitter;

use constant ACTION_CONFIG => Business::Config::Account->new()->status_actions()->{config};

=head2 _get_action_config

Get the action config for a given status code.

=over 4

=item * C<status_code> - The status code for which the action config is to be fetched.

=back

Returns an arrayref of action config in the format
    [
        {
            name => 'event_1_name',
            default_args => ['arg1', 'arg2']
        },
        {
            name => 'event_2_name',
            default_args => ['arg1', 'arg2']
        },
        ...
    ]

=cut

sub _get_action_config {
    my $status_code = shift;
    return ACTION_CONFIG->{$status_code} // [];
}

=head2 trigger

Trigger the events for a given status code for the given client and status code, based on the configuration.

=over 4

=item * C<client_loginid> - The loginid of the client for which the status has been applied.

=item * C<status_code> - The status code that has been applied.

=item * C<additional_args> - Additional arguments to be passed to the event.

=back

=cut

sub trigger {
    my ($self, $client_loginid, $status_code, $additional_args) = @_;
    my $status_action_config = _get_action_config($status_code);
    for my $action ($status_action_config->@*) {
        my $event_name   = $action->{name};
        my $default_args = $action->{default_args};

        $default_args = {map { $_ => undef } $default_args->@*};

        my %args;

        $args{loginid} = $client_loginid            if exists $default_args->{client_loginid};
        %args          = (%args, %$additional_args) if defined $additional_args;

        BOM::Platform::Event::Emitter::emit($event_name, \%args);

    }

}

=head2 trigger_bulk

Trigger the events for a given status code for the given clients, calls trigger internally.

=over 4

=item * C<client_loginids> - An arrayref of client loginids for which the status has been applied.

=item * C<status_code> - The status code that has been applied.

=item * C<additional_args> - Additional arguments to be passed to the event.

=back

=cut

sub trigger_bulk {
    my ($self, $client_loginids, $status_code, $additional_args) = @_;

    for my $client_loginid ($client_loginids->@*) {
        trigger($self, $client_loginid, $status_code, $additional_args);
    }
}

1;

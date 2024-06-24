package BOM::Service::User::Attributes::Update::FinaliseHandlers;

use strict;
use warnings;
no indirect;

=head2 poi_check

This subroutine triggers a proof of identity (POI) check for a user. It first retrieves the client object using the user_id and correlation_id from the request. Then, it emits an event named 'poi_check_rules' with the client's loginid as the payload.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The event is emitted and handled by the event listeners.

=back

=cut

sub poi_check {
    my ($request) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Platform::Event::Emitter::emit('poi_check_rules', {loginid => $client->loginid});
}

=head2 onfido_sync

This subroutine triggers a synchronization of Onfido details for a user. It first retrieves the client object using the user_id and correlation_id from the request. Then, it emits an event named 'sync_onfido_details' with the client's loginid as the payload.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The event is emitted and handled by the event listeners.

=back

=cut

sub onfido_sync {
    my ($request) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});
}

=head2 user_password

This subroutine sends a password reset confirmation message for a user. It first retrieves the user and client objects using the user_id and correlation_id from the request. Then, it emits an event named 'reset_password_confirmation' with the client's loginid, first name, email, and the reason for the password update as the payload.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The event is emitted and handled by the event listeners.

=back

=cut

sub user_password {
    my ($request) = @_;
    my $user      = BOM::Service::Helpers::get_user_object($request->{user_id}, $request->{context}->{correlation_id});
    my $client    = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});

    # Send out the messaging
    BOM::Platform::Event::Emitter::emit(
        'reset_password_confirmation',
        {
            loginid    => $client->loginid,    # TODO - REMOVE ME, SMALL COMMENT, BIG ACTION
            properties => {
                first_name => $client->first_name,
                email      => $user->email,
                type       => $request->{flags}->{password_update_reason},
            }});
}

=head2 user_email

This subroutine triggers a synchronization of user details to MT5, CTRADER, and Onfido. It first retrieves the client object using the user_id and correlation_id from the request. Then, it emits three events: 'sync_user_to_MT5', 'sync_user_to_CTRADER', and 'sync_onfido_details' with the client's loginid as the payload. The 'sync_onfido_details' event is only emitted if the client is not virtual.

=over 4

=item * Input: HashRef (request)

=item * Return: None. The events are emitted and handled by the event listeners.

=back

=cut

sub user_email {
    my ($request) = @_;
    my $client = BOM::Service::Helpers::get_client_object($request->{user_id}, $request->{context}->{correlation_id});
    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5',     {loginid => $client->loginid});
    BOM::Platform::Event::Emitter::emit('sync_user_to_CTRADER', {loginid => $client->loginid});
    BOM::Platform::Event::Emitter::emit('sync_onfido_details',  {loginid => $client->loginid}) unless $client->is_virtual;
}

1;

package BOM::RPC::v3::Notification;

=head1 BOM::RPC::v3::Notification

This package contains methods for handling and responding to Event

=cut

use 5.014;
use strict;
use warnings;

use Syntax::Keyword::Try;
use BOM::User::Client;
use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Platform::Context qw (localize request);
use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Onfido;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Token;
use BOM::Config;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;

=head2 notification_event

notification_events enables the system to have the information of event happening in

frontend and carry out processes in accordance to the event.

=cut

requires_auth('trading', 'wallet');

rpc notification_event => sub {
    my $params = shift;

    my $loginid = $params->{token_details}->{loginid};
    my $args    = $params->{args};
    my $client  = $params->{client};

    my $event_category = delete $args->{category} // '';
    my $event          = delete $args->{event}    // '';

    # hash that contains what process should be triggered
    my $action_map = {
        authentication => {
            poi_documents_uploaded => [\&BOM::RPC::v3::Notification::_trigger_poi_check,],
        },
    };

    # check if the call is valid
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnrecognizedEvent',
            message_to_client => localize('No such category or event. Please check the provided value.')}
    ) unless $action_map->{$event_category} && $action_map->{$event_category}->{$event};

    # this contains a list of actions that will be carried out for the call
    my $actions          = $action_map->{$event_category}->{$event};
    my $all_success_flag = 1;
    for my $action (@$actions) {
        try {
            $action->($client, $args->{args} // {});
        } catch ($e) {
            $all_success_flag = 0;
            warn "Error caught in $action : " . $e;
            log_exception();
        }
    }

    return {status => $all_success_flag};

};

=head2 _trigger_poi_check($client)

_trigger_poi_check triggers the event to request for Onfido check on the client

=cut

sub _trigger_poi_check {
    my ($client, $args) = @_;

    my $user_applicant = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);

    BOM::Platform::Event::Emitter::emit(
        ready_for_authentication => {
            loginid      => $client->loginid,
            applicant_id => $user_applicant->{id},
            documents    => $args->{documents},
        });

    return 1;
}

1;

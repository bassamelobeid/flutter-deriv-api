#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script responsible to handle create or edit of the partner ID
(which only accessible by Marketing team)
and required DCC Token to approve the create or edit of the partner ID

=cut

use strict;
use warnings;
use f_brokerincludeall;

use BOM::User;
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
use BOM::MyAffiliates::DynamicWorks::Integration;

use Syntax::Keyword::Try;
use Log::Any qw($log);

BOM::Backoffice::Sysinit::init();

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO(_get_display_error_message("This page is not accessible as partners.enable_dynamic_works is disabled"))
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

my $dw_integration;

try {
    $dw_integration = BOM::MyAffiliates::DynamicWorks::Integration->new();
} catch ($e) {
    code_exit_BO(_get_display_error_message("Could not initiate integration module: $e \n"));
}

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth::get_staffname();

PrintContentType();

my $loginid       = $input->{loginid}       // '';
my $ClientLoginid = $input->{ClientLoginid} // '';
my $partner_id    = $input->{partner_id}    // '';
my $prev_dcc      = $input->{DCcode}        // '';

my $self_post = request()->url_for('backoffice/partners/set_partner_id.cgi');

BrokerPresentation("PARTNER ID DCC");
# Not available for Virtual Accounts
if (($loginid =~ BOM::User::Client->VIRTUAL_REGEX) || ($loginid =~ BOM::User::Client->MT5_REGEX)) {
    code_exit_BO("We're sorry but the Partner ID is not available for this type of Accounts.", 'CHANGE Client AFFILIATE TOKEN DCC');
}

my $client = BOM::User::Client->new({loginid => $loginid});

code_exit_BO(_get_display_error_message("Client [$loginid] not found.")) unless $client;

my $affiliated_client_details = $client->user->get_affiliated_client_details;

code_exit_BO(_get_display_error_message("ERROR: Client already linked to a partner!"))
    if defined $affiliated_client_details && $affiliated_client_details->{partner_token};

BOM::Backoffice::Request::template()->process(
    'backoffice/partners/set_partner_id.html.tt',
    {
        clerk         => encode_entities($clerk),
        loginid       => $loginid,
        ClientLoginid => $ClientLoginid,
        partner_id    => $partner_id,
        prev_dcc      => $prev_dcc,
    });

code_exit_BO();

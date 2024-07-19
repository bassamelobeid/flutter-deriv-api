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

my $dw_integration;

try {
    $dw_integration = BOM::MyAffiliates::DynamicWorks::Integration->new();
} catch ($e) {
    code_exit_BO(_get_display_error_message("Could not initiate integration module: $e \n"));
}

BOM::Backoffice::Sysinit::init();

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO(_get_display_error_message("This page is not accessible as partners.enable_dynamic_works is disabled"))
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth::get_staffname();

PrintContentType();

my $ClientLoginid = $input->{ClientLoginid} // '';
my $partner_id    = $input->{partner_id}    // '';
my $prev_dcc      = $input->{DCcode}        // '';
my $sidcs;

BrokerPresentation("PARTNER SIDC");
# Not available for Virtual Accounts
if (($ClientLoginid =~ BOM::User::Client->VIRTUAL_REGEX) || ($ClientLoginid =~ BOM::User::Client->MT5_REGEX)) {
    code_exit_BO("We're sorry but the Partner ID is not available for this type of Accounts.", 'CHANGE Client AFFILIATE TOKEN DCC');
}

my $client;
try {
    $client = BOM::User::Client->new({loginid => $ClientLoginid});
} catch ($e) {
    $log->warnf("Error when get client of login id $ClientLoginid. more detail: %s", $e);
}

my $self_post = request()->url_for('backoffice/partners/select_partner_sidc.cgi');

if ($input->{EditPartnerIDWithSIDC}) {

    my $sidc = $input->{PartnerSIDC};

    code_exit_BO(_get_display_error_message("SIDC is required to edit partner ID")) unless $sidc;

    my $user = $client->user;

    BOM::Platform::Event::Emitter::emit(
        'link_user_to_dw_affiliate',
        {
            binary_user_id => $user->id,
            affiliate_id   => $partner_id,
            sidc           => $sidc,
        });

    my $msg =
          Date::Utility->new->datetime . " "
        . " Edit partner token for "
        . $ClientLoginid
        . " by clerk=$clerk (DCcode="
        . ($input->{DCcode} // 'No DCode provided')
        . ") $ENV{REMOTE_ADDR}";

    BOM::User::AuditLog::log($msg, '', $clerk);

    $msg = 'Edit Partner ID completed successfully.';
    code_exit_BO(_get_display_message($msg));
} else {
    try {
        $sidcs = $dw_integration->get_sidcs($partner_id);
    } catch ($e) {
        code_exit_BO(_get_display_error_message("ERROR: SIDCS could not be fetched! " . $e));
    }

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{EditPartnerID}})->validate_client_control_code($input->{DCcode}, $client->email, $client->binary_user_id);
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    BOM::Backoffice::Request::template()->process(
        'backoffice/partners/select_partner_sidc.html.tt',
        {
            clerk         => encode_entities($clerk),
            ClientLoginid => $ClientLoginid,
            partner_id    => $partner_id,
            prev_dcc      => $prev_dcc,
            sidcs         => $sidcs,
        });

}

code_exit_BO();

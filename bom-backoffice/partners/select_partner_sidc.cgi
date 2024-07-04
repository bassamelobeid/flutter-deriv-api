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

my $dw_integration = BOM::MyAffiliates::DynamicWorks::Integration->new();

# my $sidcs = [
#     {
#         id    => "9",
#         title => "Deriv Test",
#         sidc  => "59EC9971-9585-48AD-9FB0-D3AC05D00607",
#         sidi  => "8641E891-7164-46A0-A411-BB830D73FBCD"
#     }
# ];

BOM::Backoffice::Sysinit::init();

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO("This page is not accessible as partners.enable_dynamic_works is disabled")
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth::get_staffname();

PrintContentType();

my $loginid       = $input->{loginid}       // '';
my $ClientLoginid = $input->{ClientLoginid} // '';
my $partner_id    = $input->{partner_id}    // '';
my $prev_dcc      = $input->{DCcode}        // '';

my $sidcs = $dw_integration->get_sidcs($partner_id);

code_exit_BO(_get_display_error_message("ERROR: SIDCS could not be fetched!")) unless $sidcs;

my $self_post = request()->url_for('backoffice/partners/select_partner_sidc.cgi');

BrokerPresentation("PARTNER SIDC");
# Not available for Virtual Accounts
if (($loginid =~ BOM::User::Client->VIRTUAL_REGEX) || ($loginid =~ BOM::User::Client->MT5_REGEX)) {
    code_exit_BO("We're sorry but the Partner ID is not available for this type of Accounts.", 'CHANGE Client AFFILIATE TOKEN DCC');
}

if ($input->{EditPartnerIDWithSIDC}) {

    my $sidc = $input->{PartnerSIDC};

    code_exit_BO("SIDC is required to edit partner ID") unless $sidc;

    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $ClientLoginid});
    } catch ($e) {
        $log->warnf("Error when get client of login id $ClientLoginid. more detail: %s", $e);
    }

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
    BOM::Backoffice::Request::template()->process(
        'backoffice/partners/select_partner_sidc.html.tt',
        {
            clerk         => encode_entities($clerk),
            loginid       => $loginid,
            ClientLoginid => $ClientLoginid,
            partner_id    => $partner_id,
            prev_dcc      => $prev_dcc,
            sidcs         => $sidcs,
        });

}

code_exit_BO();

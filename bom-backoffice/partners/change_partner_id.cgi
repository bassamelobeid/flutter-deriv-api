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

my $dw_integration = BOM::MyAffiliates::DynamicWorks::Integration->new();

use Syntax::Keyword::Try;
use Log::Any qw($log);

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

my $self_post = request()->url_for('backoffice/partners/change_partner_id.cgi');

BrokerPresentation("PARTNER ID DCC");
# Not available for Virtual Accounts
if (($loginid =~ BOM::User::Client->VIRTUAL_REGEX) || ($loginid =~ BOM::User::Client->MT5_REGEX)) {
    code_exit_BO("We're sorry but the Partner ID is not available for this type of Accounts.", 'CHANGE Client AFFILIATE TOKEN DCC');
}

BOM::Backoffice::Request::template()->process(
    'backoffice/partners/change_partner_id.html.tt',
    {
        clerk         => encode_entities($clerk),
        loginid       => $loginid,
        ClientLoginid => $ClientLoginid,
        partner_id    => $partner_id,
        prev_dcc      => $prev_dcc,
    });

if ($input->{EditPartnerID}) {

    #Error checking
    code_exit_BO(_get_display_error_message("ERROR: Please provide client loginid"))       unless $input->{ClientLoginid};
    code_exit_BO(_get_display_error_message("ERROR: Please provide a dual control code"))  unless $input->{DCcode};
    code_exit_BO(_get_display_error_message("ERROR: You must check the verification box")) unless $input->{verification};
    code_exit_BO(_get_display_error_message("ERROR: Invalid operation"))                   unless $input->{EditPartnerID} eq 'Edit affiliates token';
    code_exit_BO(_get_display_error_message("ERROR: Invalid partner_id provided!"))
        if $partner_id and $partner_id !~ m/^[a-zA-Z0-9-_]+$/;

    my $ClientLoginid  = trim(uc $input->{ClientLoginid});
    my $well_formatted = check_client_login_id($ClientLoginid);
    code_exit_BO(_get_display_error_message("ERROR: Invalid Login ID provided!")) unless $well_formatted;
    if (($ClientLoginid =~ /^VR/) || ($ClientLoginid =~ /^MT[DR]?\d+$/)) {
        code_exit_BO(_get_display_error_message("ERROR: Partner ID is not available for this type of Accounts.!"));
    }

    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $ClientLoginid});
    } catch ($e) {
        $log->warnf("Error when get client of login id $ClientLoginid. more detail: %s", $e);
    }

    code_exit_BO(
        qq[<p>ERROR: Client [$ClientLoginid] not found. </p>
            <form action="$self_post" method="get">
                Try Again: <input type="text" name="loginID" size="15" value="$ClientLoginid" data-lpignore="true" />
                <input type="submit" value="Search" />
            </form>]
    ) unless $client;

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{EditPartnerID}})->validate_client_control_code($input->{DCcode}, $client->email, $client->binary_user_id);
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if !$dcc_error;

}

code_exit_BO();

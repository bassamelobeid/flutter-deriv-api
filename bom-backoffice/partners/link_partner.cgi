#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script responsible to handle the linking to DW Partner ID to Partner Deriv account
(which only accessible by Marketing team)
and required DCC Token to approve the linking of the DW and deriv partner account

=cut

use strict;
use warnings;
use f_brokerincludeall;

use BOM::User;
use BOM::Config::Runtime;
use BOM::MyAffiliates::DynamicWorks::Integration;
use BOM::MyAffiliates;
use BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel;

use Syntax::Keyword::Try;
use Log::Any   qw($log);
use List::Util qw(first);

BOM::Backoffice::Sysinit::init();

my $dynamicWorksIntegration = BOM::MyAffiliates::DynamicWorks::Integration->new();
my $myaffiliates            = BOM::MyAffiliates->new();
my $db                      = BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel->new();

use constant {
    DYNAMICWORKS => 'dynamicworks',
    MYAFFILIATES => 'myaffiliate',
};

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO(_get_display_error_message("This page is not accessible as partners.enable_dynamic_works is disabled"))
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth::get_staffname();

PrintContentType();

my $loginid       = $input->{loginid}       // '';
my $ClientLoginid = $input->{ClientLoginid} // '';
my $partner_id    = $input->{partner_id}    // '';
my $prev_dcc      = $input->{DCcode}        // '';

my $self_post = request()->url_for('backoffice/partners/link_partner.cgi');

BrokerPresentation("PARTNER ID DCC");
# Not available for Virtual Accounts
if (($loginid =~ BOM::User::Client->VIRTUAL_REGEX) || ($loginid =~ BOM::User::Client->MT5_REGEX)) {
    code_exit_BO("We're sorry but the Partner ID is not available for this type of Accounts.", 'LINK AFFILIATE ID DCC');
}

BOM::Backoffice::Request::template()->process(
    'backoffice/partners/link_partner.html.tt',
    {
        clerk         => encode_entities($clerk),
        loginid       => $loginid,
        ClientLoginid => $ClientLoginid,
        partner_id    => $partner_id,
        prev_dcc      => $prev_dcc
    });

sub check_dynamicworks_profile {

    my ($client, $partner_id, $dynamicWorksIntegration) = @_;

    my $response = $dynamicWorksIntegration->get_user_profiles($partner_id);
    print($response);
    code_exit_BO(_get_display_error_message("ERROR: The given partner does not exist in DynamicWorks")) unless $response;

    my $dw_user_profile = first { defined $_->{email} } @$response;

    code_exit_BO(_get_display_error_message("ERROR: The given partner email does not match the email in the clients account"))
        if $dw_user_profile->{email} ne $client->user->email;

    return 1;

}

sub check_myaffiliates_profile {
    my ($client, $myaffiliates) = @_;

    # Checking both MyAffiliates API and UserDB for affiliate records
    my $affiliate = $client->user->affiliate();
    $affiliate = (defined $affiliate->{affiliate_id}) && ($affiliate->{affiliate_id} ne 'N/A') ? $affiliate->{affiliate_id} : undef;

    my $existing_affiliate = $affiliate or $myaffiliates->check_myaffiliates_user_by_email($client->user->email);

    code_exit_BO(_get_display_error_message("ERROR: The users email found in myaffiliates cannot link DynamicWorks Account"))
        if $existing_affiliate;

    return 1;
}

if ($input->{LinkPartner}) {

    #Error checking
    code_exit_BO(_get_display_error_message("ERROR: Please provide client loginid"))      unless $input->{ClientLoginid};
    code_exit_BO(_get_display_error_message("ERROR: Please provide a dual control code")) unless $input->{DCcode};
    code_exit_BO(_get_display_error_message("ERROR: Invalid operation"))                  unless $input->{LinkPartner} eq 'Link partner';
    code_exit_BO(_get_display_error_message("ERROR: Invalid partner_id provided!"))
        if $partner_id and $partner_id !~ m/^CU[a-zA-Z0-9-_]*$/;

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
            transactiontype => $input->{LinkPartner}})->validate_client_control_code($input->{DCcode}, $client->email, $client->binary_user_id);
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    check_dynamicworks_profile($client, $partner_id, $dynamicWorksIntegration);
    check_myaffiliates_profile($client, $myaffiliates);

    # Setting affiliate details in DB
    my $args = {
        binary_user_id        => $client->binary_user_id,
        external_affiliate_id => $partner_id,
        payment_loginid       => $client->loginid,
        payment_currency      => $client->account->currency_code,
        provider              => DYNAMICWORKS
    };

    my $response = $db->add_new_affiliate($args);

    code_exit_BO(_get_display_error_message("ERROR: Saving details for partner . Error Message : $response->{error}")) unless $response->{success};

    code_exit_BO(_get_display_message("Details Saved Successfully the affiliate id is : $response->{affiliate_id}")) if $response->{success};

    my $msg =
          Date::Utility->new->datetime . " "
        . " Link partner token for "
        . $ClientLoginid
        . " by clerk=$clerk (DCcode="
        . ($input->{DCcode} // 'No DCode provided')
        . ") $ENV{REMOTE_ADDR}";

    BOM::User::AuditLog::log($msg, '', $clerk);

    $msg = 'Edit Partner ID completed successfully.';
    code_exit_BO(_get_display_message($msg));
}

code_exit_BO();

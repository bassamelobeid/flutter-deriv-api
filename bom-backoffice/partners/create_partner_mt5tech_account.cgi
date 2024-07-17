#!/etc/rmg/bin/perl
package main;

=pod
=head1 DESCRIPTION
This script responsible to create an event for MT5 technical account. 
(which only accessible by Marketing team)
and required DCC Token to approve
=cut

use strict;
use warnings;
use f_brokerincludeall;

use BOM::User;
use BOM::Config::Runtime;
use BOM::MyAffiliates;
use BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel;

use Syntax::Keyword::Try;
use Log::Any   qw($log);
use List::Util qw(first);
use BOM::Platform::Event::Emitter;

BOM::Backoffice::Sysinit::init();

my $myaffiliates = BOM::MyAffiliates->new();
my $db           = BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel->new();

use constant {
    DYNAMICWORKS => 'dynamicworks',
    MYAFFILIATES => 'myaffiliate',
};

BOM::Config::Runtime->instance->app_config->check_for_update();

code_exit_BO("This page is not accessible as partners.enable_dynamic_works is disabled")
    unless BOM::Config::Runtime->instance->app_config->partners->enable_dynamic_works;

my $input = request()->params;

my $clerk = BOM::Backoffice::Auth::get_staffname();

PrintContentType();

my $mt5_account_id = $input->{mt5_account_id} // '';
my $prev_dcc       = $input->{DCcode}         // '';
my $loginid        = $input->{loginid}        // '';

my $self_post = request()->url_for('backoffice/partners/create_partner_mt5tech_account.cgi');

BrokerPresentation("PARTNER MT5 account DCC");
# Only available for MT5 Accounts

BOM::Backoffice::Request::template()->process(
    'backoffice/partners/create_partner_mt5tech_account.html.tt',
    {
        clerk          => encode_entities($clerk),
        loginid        => $loginid,
        mt5_account_id => $mt5_account_id,
        prev_dcc       => $prev_dcc
    });

if ($input->{CreatePartnerMT5TechnicalAccount}) {
    #Error checking
    code_exit_BO(_get_display_error_message("ERROR: Please provide partner mt5 account id")) unless $input->{mt5_account_id};
    code_exit_BO(_get_display_error_message("ERROR: Please provide a dual control code"))    unless $input->{DCcode};

    if (!($mt5_account_id =~ BOM::User::Client->MT5_REGEX)) {
        code_exit_BO("We're sorry but the functionality is not available for this type of Accounts.", 'CREATE MT5 technical account DCC');
    }

    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $loginid});
    } catch ($e) {
        $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
    }

    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input->{CreatePartnerMT5TechnicalAccount}}
    )->validate_client_control_code($input->{DCcode}, $client->email, $client->binary_user_id);
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    my $dw_id =
        $db->get_affiliates({binary_user_id => $client->{binary_user_id}, provider => 'dynamicworks'})->{affiliates}->[0]->{external_affiliate_id};

    if (!defined($dw_id)) {
        code_exit_BO(_get_display_error_message("Partner DW details does not exist"));
    }

    BOM::Platform::Event::Emitter::emit(
        'create_mt5_ib_technical_accounts',
        {
            binary_user_id => $client->binary_user_id,
            mt5_account_id => $mt5_account_id,
            provider       => DYNAMICWORKS,
            partner_id     => $dw_id
        });

    my $msg = 'Partner technical account creation started successfully. You will receive a notification via email.';
    code_exit_BO(_get_display_message($msg));

}
code_exit_BO();

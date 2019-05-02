#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Try::Tiny;
use HTML::Entities;
use Scalar::Util qw(looks_like_number);

use BOM::User::Client::PaymentAgent;
use BOM::User qw( is_payment_agents_suspended_in_country );
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Form;
use BOM::Config::PaymentAgent;
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Payment Agent Setting');
my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::get_staffname();

my $loginid         = request()->param('loginid');
my $whattodo        = request()->param('whattodo');
my $encoded_loginid = encode_entities($loginid);

Bar('Payment Agent Setting');

print "<b>Please note that payment agent currency and country of service will be same as client account currency and residence respectively.</b>";

if ($whattodo eq 'create') {
    my $client = BOM::User::Client->new({loginid => $loginid});

    code_exit_BO("Error : wrong loginid ($loginid) could not get client instance")                 unless $client;
    code_exit_BO("Client has not set account currency. Currency is mandatory for payment agent")   unless $client->default_account;
    code_exit_BO("Please note that to become payment agent client has to be fully authenticated.") unless $client->fully_authenticated;
    code_exit_BO("Payment agents are suspended in client's residence country.") if is_payment_agents_suspended_in_country($client->residence);

    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form($loginid, $broker);
    print $payment_agent_registration_form->build();

    code_exit_BO();
}

if ($whattodo eq 'show') {
    my $pa = BOM::User::Client::PaymentAgent->new({loginid => $loginid});
    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form($loginid, $broker);

    my $input_fields = {
        pa_name            => $pa->payment_agent_name,
        pa_summary         => $pa->summary,
        pa_email           => $pa->email,
        pa_tel             => $pa->phone,
        pa_url             => $pa->url,
        pa_comm_depo       => $pa->commission_deposit,
        pa_comm_with       => $pa->commission_withdrawal,
        pa_max_withdrawal  => $pa->max_withdrawal,
        pa_min_withdrawal  => $pa->min_withdrawal,
        pa_info            => $pa->information,
        pa_auth            => ($pa->is_authenticated ? 'yes' : 'no'),
        pa_listed          => ($pa->is_listed ? 'yes' : 'no'),
        pa_supported_banks => $pa->supported_banks,
    };

    $payment_agent_registration_form->set_input_fields($input_fields);

    my $page_content = '<p>' . $payment_agent_registration_form->build();
    print $page_content;

    code_exit_BO();
} elsif ($whattodo eq 'apply') {
    my $client = BOM::User::Client->new({loginid => $loginid});
    code_exit_BO("Error : wrong loginid ($loginid) could not get client instance") unless $client;
    code_exit_BO("Client has not set account currency. Currency is mandatory for payment agent") unless $client->default_account;
    code_exit_BO("Payment agents are suspended in client's residence country.") if is_payment_agents_suspended_in_country($client->residence);

    my $pa = BOM::User::Client::PaymentAgent->new({loginid => $loginid});
    unless ($pa) {
        # if its new so we need to set it
        $pa = $client->set_payment_agent;
    }

    my $currency = $pa->currency_code // $client->default_account->currency_code;

    my $max_withdrawal = request()->param('pa_max_withdrawal');
    my $min_withdrawal = request()->param('pa_min_withdrawal');

    code_exit_BO("Invalid amount: requested minimum amount must be greater than zero.")
        if (looks_like_number($min_withdrawal) and $min_withdrawal <= 0);
    code_exit_BO("Invalid amount: requested maximum amount must be greater than zero.")
        if (looks_like_number($max_withdrawal) and $max_withdrawal <= 0);
    code_exit_BO("Invalid amount: requested maximum amount must be greater than minimum amount.")
        if (looks_like_number($max_withdrawal) and looks_like_number($min_withdrawal) and $max_withdrawal < $min_withdrawal);

    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);
    $max_withdrawal = $max_withdrawal || $min_max->{maximum};
    $min_withdrawal = $min_withdrawal || $min_max->{minimum};

    # update payment agent file
    $pa->payment_agent_name(request()->param('pa_name'));
    $pa->target_country($client->residence);
    $pa->summary(request()->param('pa_summary'));
    $pa->email(request()->param('pa_email'));
    $pa->phone(request->param('pa_tel'));
    $pa->url(request()->param('pa_url'));
    $pa->commission_deposit(request()->param('pa_comm_depo')    || 0);
    $pa->commission_withdrawal(request()->param('pa_comm_with') || 0);
    $pa->max_withdrawal($max_withdrawal);
    $pa->min_withdrawal($min_withdrawal);
    $pa->information(request()->param('pa_info'));
    $pa->supported_banks(request()->param('pa_supported_banks'));
    $pa->is_authenticated(request()->param('pa_auth') eq 'yes');
    $pa->is_listed(request()->param('pa_listed') eq 'yes');
    $pa->currency_code($currency);

    $pa->save || die "failed to save payment_agent!";

    print "<p style=\"color:green; font-weight:bold;\">Successfully updated payment agent details for [$encoded_loginid]</p>";

    my $auditt_href = request()->url_for(
        "backoffice/show_audit_trail.cgi",
        {
            broker   => $broker,
            category => 'payment_agent',
            loginid  => $loginid
        });

    my $return_href = request()->url_for(
        "backoffice/f_clientloginid_edit.cgi",
        {
            broker  => $broker,
            loginID => $loginid
        });

    print qq(<a href="$auditt_href">&laquo; Show payment-agent audit trail for $encoded_loginid</a><br/><br/>);
    print qq(<a href="$return_href">&laquo; Return to client details<a/>);

    code_exit_BO();
}

1;


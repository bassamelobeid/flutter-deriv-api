#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Runtime;
use BOM::View::CGIForm;
use f_brokerincludeall;
system_initialize();

PrintContentType();
BrokerPresentation('Payment Agent Setting');
my $broker = request()->broker->code;
my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};

my $loginid  = request()->param('loginid');
my $whattodo = request()->param('whattodo');

Bar('Payment Agent Setting');

my $pa = BOM::Platform::Client::PaymentAgent->new({loginid => $loginid});
if (not $pa) {
    print "Error: client [$loginid] is not payment agent";
    code_exit_BO();
}

if ($whattodo eq 'show') {
    my $payment_agent_registration_form = BOM::View::CGIForm::get_payment_agent_registration_form($loginid, $broker);

    my $input_fields = {
        pa_name            => $pa->payment_agent_name,
        pa_target_country  => $pa->target_country,
        pa_summary         => $pa->summary,
        pa_email           => $pa->email,
        pa_tel             => $pa->phone,
        pa_url             => $pa->url,
        pa_comm_depo       => $pa->comission_deposit,
        pa_comm_with       => $pa->comission_withdrawal,
        pa_info            => $pa->information,
        pa_auth            => ($pa->is_authenticated ? 'yes' : 'no'),
        pa_supported_banks => $pa->supported_banks,
    };

    foreach my $avail_curr (@{request()->available_currencies}) {
        $avail_curr =~ /USD|GBP/ or next;
        for my $pa_curr ($pa->currency_code, $pa->currency_code_2) {
            next unless $pa_curr && $pa_curr eq $avail_curr;
            $input_fields->{"pa_curr_$pa_curr"} = $pa_curr;
        }
    }

    $payment_agent_registration_form->set_input_fields($input_fields);

    my $page_content = '<p>' . $payment_agent_registration_form->build();
    print $page_content;

    code_exit_BO();
} elsif ($whattodo eq 'apply') {

    # curr-codes are hidden fields set at form-build time.
    # set 1st curr-code if USD or GBP present.
    # set 2nd curr-code if both are present.
    # fallback to emptystring because db is (wrongly) not-null here.
    $pa->currency_code(request()->param('pa_curr_USD') || request()->param('pa_curr_GBP') || '');
    $pa->currency_code_2(request()->param('pa_curr_USD') && request()->param('pa_curr_GBP') || '');

    # update payment agent file
    $pa->payment_agent_name(request()->param('pa_name'));
    $pa->target_country(request()->param('pa_target_country'));
    $pa->summary(request()->param('pa_summary'));
    $pa->email(request()->param('pa_email'));
    $pa->phone(request->param('pa_tel'));
    $pa->url(request()->param('pa_url'));
    $pa->comission_deposit(request()->param('pa_comm_depo')    || 0);
    $pa->comission_withdrawal(request()->param('pa_comm_with') || 0);
    $pa->information(request()->param('pa_info'));
    $pa->supported_banks(request()->param('pa_supported_banks'));
    $pa->is_authenticated(request()->param('pa_auth') eq 'yes');

    $pa->save || die "failed to save payment_agent!";

    print "<p style=\"color:green; font-weight:bold;\">Successfully updated payment agent details for [$loginid]</p>";

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

    print qq(<a href="$auditt_href">&laquo; Show payment-agent audit trail for $loginid</a><br/><br/>);
    print qq(<a href="$return_href">&laquo; Return to client details<a/>);

    code_exit_BO();
}

1;


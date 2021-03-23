#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use Scalar::Util qw(looks_like_number);
use Syntax::Keyword::Try;

use BOM::User::Client::PaymentAgent;
use BOM::User qw( is_payment_agents_suspended_in_country );
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Form;
use BOM::Config::PaymentAgent;
use BOM::Backoffice::Utility;
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my %MAP_FIELDS = (
    pa_name                      => 'payment_agent_name',
    pa_coc_approval              => 'code_of_conduct_approval',
    pa_email                     => 'email',
    pa_tel                       => 'phone',
    pa_url                       => 'url',
    pa_comm_depo                 => 'commission_deposit',
    pa_comm_with                 => 'commission_withdrawal',
    pa_max_withdrawal            => 'max_withdrawal',
    pa_min_withdrawal            => 'min_withdrawal',
    pa_info                      => 'information',
    pa_auth                      => 'is_authenticated',
    pa_listed                    => 'is_listed',
    pa_supported_payment_methods => 'supported_banks',
    pa_countries                 => 'target_country',
    pa_affiliate_id              => 'affiliate_id',
);

PrintContentType();
BrokerPresentation('Payment Agent Setting');
my $broker = request()->broker_code;
my $clerk  = BOM::Backoffice::Auth0::get_staffname();

my $loginid         = request()->param('loginid');
my $whattodo        = request()->param('whattodo');
my $encoded_loginid = encode_entities($loginid);

Bar('Payment Agent Setting');

print
    "<p>NOTE: Payment agent account currency will be the same as client's account currency & allowed country of service will be as per target countries provided.</p>";

if ($whattodo eq 'create') {
    my $client = BOM::User::Client->new({loginid => $loginid});

    code_exit_BO("Error : wrong loginid ($loginid) could not get client instance")                 unless $client;
    code_exit_BO("Client has not set account currency. Currency is mandatory for payment agent")   unless $client->default_account;
    code_exit_BO("Please note that to become payment agent client has to be fully authenticated.") unless $client->fully_authenticated;
    code_exit_BO("Payment agents are suspended in client's residence country.") if is_payment_agents_suspended_in_country($client->residence);

    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form($loginid, $broker);
    $payment_agent_registration_form->set_input_fields({
        'pa_name'      => $client->full_name,
        'pa_email'     => $client->email,
        'pa_tel'       => $client->phone,
        'pa_comm_depo' => '0.00',
        'pa_comm_with' => '0.00',
    });
    print $payment_agent_registration_form->build();

    code_exit_BO();
}

my $pa = BOM::User::Client::PaymentAgent->new({loginid => $loginid});

if ($whattodo eq 'show') {
    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form($loginid, $broker);
    my $pa_countries                    = $pa->get_countries;

    my %input_fields = map { my $sub_name = $MAP_FIELDS{$_}; $_ => $pa->$sub_name } keys %MAP_FIELDS;
    $input_fields{$_} = $input_fields{$_} ? 'yes' : 'no' for (qw/pa_coc_approval pa_auth pa_listed/);
    $input_fields{$_} ||= '0.00' for (qw/pa_comm_depo pa_comm_with/);
    $input_fields{pa_countries} = join(',', @$pa_countries);

    $payment_agent_registration_form->set_input_fields(\%input_fields);

    my $page_content = '<p>' . $payment_agent_registration_form->build();
    print $page_content;

    code_exit_BO();
} elsif ($whattodo eq 'apply') {
    my $client = BOM::User::Client->new({loginid => $loginid});
    code_exit_BO("Error : wrong loginid ($loginid) could not get client instance")               unless $client;
    code_exit_BO("Client has not set account currency. Currency is mandatory for payment agent") unless $client->default_account;
    code_exit_BO("Payment agents are suspended in client's residence country.") if is_payment_agents_suspended_in_country($client->residence);
    code_exit_BO("Error : must provide at least one country.") unless request()->param('pa_countries');

    my @countries = split(',', request()->param('pa_countries'));
    my $editing   = 1;
    unless ($pa) {
        # if its new so we need to set it
        $pa      = $client->set_payment_agent;
        $editing = 0;
    }

    my $currency = $pa->currency_code // $client->default_account->currency_code;

    my $max_withdrawal = request()->param('pa_max_withdrawal');
    my $min_withdrawal = request()->param('pa_min_withdrawal');

    code_exit_BO("Invalid amount: requested minimum withdrawal amount must be greater than zero.")
        if (looks_like_number($min_withdrawal) and $min_withdrawal <= 0);
    code_exit_BO("Invalid amount: requested maximum withdrawal amount must be greater than zero.")
        if (looks_like_number($max_withdrawal) and $max_withdrawal <= 0);
    code_exit_BO("Invalid amount: requested maximum withdrawal amount must be greater than minimum amount.")
        if (looks_like_number($max_withdrawal) and looks_like_number($min_withdrawal) and $max_withdrawal < $min_withdrawal);

    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);
    $max_withdrawal = $max_withdrawal || $min_max->{maximum};
    $min_withdrawal = $min_withdrawal || $min_max->{minimum};

    my $pa_comm_depo = request()->param('pa_comm_depo') + 0;
    my $pa_comm_with = request()->param('pa_comm_with') + 0;
    code_exit_BO("Invalid deposint commission amount: it should be between 0 and 9")   unless $pa_comm_depo >= 0 and $pa_comm_depo <= 9;
    code_exit_BO("Invalid withdrawal commission amount: it should be between 0 and 9") unless $pa_comm_with >= 0 and $pa_comm_with <= 9;

    my %args = map { $MAP_FIELDS{$_} => request()->param($_) } keys %MAP_FIELDS;
    $args{$_} = ($args{$_} eq 'yes') for (qw/is_authenticated is_listed code_of_conduct_approval/);
    $args{currency_code} = $currency;
    # let's skip COC apprival if a PA is being edited.
    $args{code_of_conduct_approval} = 1 if $editing;
    try {
        %args = $pa->validate_payment_agent_details(%args)->%*;
    } catch ($error) {
        my $message;
        if (ref $error) {
            my $lables = BOM::Backoffice::Utility::payment_agent_column_labels();
            $message = "$error->{code}";
            $message =~ s/([A-Z])/ $1/g;
            $message .= " ($error->{message})"        if $error->{message};
            $message = 'Required fields are missing ' if ($message eq 'InputValidationFailed');
            $message .= ': ' . join(',', (map { $lables->{$_} // $_ } $error->{details}->{fields}->@*))
                if $error->{code} ne 'DuplicateName' and $error->{details}->{fields};

        } else {
            chomp $error;
            $message = $error;
        }
        code_exit_BO(encode_entities("Error - $message"));
    }
    # update payment agent fields
    $args{code_of_conduct_approval} = request()->param('pa_coc_approval') eq 'yes' ? 1 : 0;
    $pa->$_($args{$_}) for keys %args;

    $pa->save || die "failed to save payment_agent!";
    code_exit_BO("Invalid Countries: could not add countries.")
        unless ($client->get_payment_agent->set_countries(\@countries));

    print "<p class='success'>Successfully updated payment agent details for [$encoded_loginid]</p><br/>";

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

    print qq(<a class='link' href="$auditt_href">&laquo; Show payment-agent audit trail for $encoded_loginid</a><br/>);
    print qq(<a class='link' href="$return_href">&laquo; Return to client details<a/>);

    code_exit_BO();
}

1;


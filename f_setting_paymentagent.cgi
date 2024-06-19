#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use Scalar::Util qw(looks_like_number);
use Syntax::Keyword::Try;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw/financialrounding/;
use List::Util                       qw(none);
use List::MoreUtils                  qw(any);
use BOM::User::Client::PaymentAgent;
use BOM::User                     qw( is_payment_agents_suspended_in_country );
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Form;
use BOM::Config::PaymentAgent;
use BOM::Backoffice::Utility;
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
BOM::Backoffice::Sysinit::init();

use constant MAP_FIELDS => {
    pa_name                      => 'payment_agent_name',
    pa_risk_level                => 'risk_level',
    pa_coc_approval              => 'code_of_conduct_approval',
    pa_email                     => 'email',
    pa_tel                       => 'phone_numbers',
    pa_url                       => 'urls',
    pa_comm_depo                 => 'commission_deposit',
    pa_comm_with                 => 'commission_withdrawal',
    pa_max_withdrawal            => 'max_withdrawal',
    pa_min_withdrawal            => 'min_withdrawal',
    pa_info                      => 'information',
    pa_status                    => 'status',
    pa_listed                    => 'is_listed',
    pa_supported_payment_method  => 'supported_payment_methods',
    pa_countries                 => 'target_country',
    pa_affiliate_id              => 'affiliate_id',
    pa_status_comment            => 'status_comment',
    pa_services_allowed_comments => 'services_allowed_comments',
    pa_tier_id                   => 'tier_id',
};

sub _prepare_display_values {
    my ($pa) = @_;
    my %input_fields = map { my $sub_name = MAP_FIELDS->{$_}; $_ => $pa->$sub_name // '' } keys MAP_FIELDS->%*;
    # convery 0/1 to yes/no
    $input_fields{$_} = $input_fields{$_} ? 'yes' : 'no' for (qw/pa_coc_approval pa_auth pa_listed/);
    $input_fields{$_} ||= '0.00' for (qw/pa_comm_depo pa_comm_with/);

    my $pa_countries = $pa->get_countries;
    $input_fields{pa_countries} = join(',', @$pa_countries);

    for my $field (qw/pa_url pa_tel pa_supported_payment_method/) {
        my $main_attr = $pa->details_main_field->{MAP_FIELDS->{$field}};
        $input_fields{$field} = join "\n", (map { $_->{$main_attr} } $input_fields{$field}->@*);
    }
    return \%input_fields;
}

sub _get_tiers {
    my ($client) = @_;

    return $client->db->dbic->run(fixup => sub { $_->selectall_arrayref('SELECT id, name from betonmarkets.pa_tier_list(NULL)', {Slice => {}}) });
}

PrintContentType();
BrokerPresentation('Payment Agent Setting');
my $broker          = request()->broker_code;
my $loginid         = request()->param('loginid');
my $whattodo        = request()->param('whattodo') // '';
my $encoded_loginid = encode_entities($loginid);
my $status          = request->param('pa_status') // '';
my $status_comment  = request->param('pa_status_comment');

if (any { $_ eq $status } qw/suspended verified rejected/) {
    code_exit_BO("Error : payment agent status <b>$status</b> should include a comment") unless $status_comment;
}

unless ($loginid) {
    code_exit_BO('Please provide client loginid.', 'Payment Agent Setting', BOM::Backoffice::Utility::redirect_login());
}

Bar('Payment Agent Setting');

print
    "<p>NOTE: Payment agent account currency will be the same as client's account currency & allowed country of service will be as per target countries provided.</p>";

if ($whattodo eq 'create') {
    my $client = BOM::User::Client->new({loginid => $loginid});
    code_exit_BO("Error : wrong loginid ($loginid) could not get client instance")                 unless $client;
    code_exit_BO("Client has not set account currency. Currency is mandatory for payment agent")   unless $client->default_account;
    code_exit_BO("Please note that to become payment agent client has to be fully authenticated.") unless $client->fully_authenticated;
    code_exit_BO("Payment agents are suspended in client's residence country.") if is_payment_agents_suspended_in_country($client->residence);

    my $values = {
        pa_name                      => $client->full_name,
        pa_email                     => $client->email,
        pa_tel                       => $client->phone,
        pa_comm_depo                 => '0.00',
        pa_comm_with                 => '0.00',
        pa_coc_approval              => 'yes',
        pa_services_allowed_comments => ''
    };

    # try to copy from a sibling payment agent
    if (my $sibling_pa = first { $_->get_payment_agent } $client->user->clients) {
        $values = _prepare_display_values($sibling_pa->get_payment_agent);

        # convert limits
        for my $limit (qw/pa_max_withdrawal pa_min_withdrawal/) {
            $values->{$limit} = convert_currency($values->{$limit}, $sibling_pa->currency, $client->currency);
            $values->{$limit} = financialrounding('amount', $client->currency, $values->{$limit});
        }
    }

    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form({
        loginid => $loginid,
        broker  => $broker,
        tiers   => _get_tiers($client),
    });
    $payment_agent_registration_form->set_input_fields($values);
    print $payment_agent_registration_form->build();

    code_exit_BO();
}

my $pa = BOM::User::Client::PaymentAgent->new({loginid => $loginid});

if ($whattodo eq 'show') {

    my $payment_agent_registration_form = BOM::Backoffice::Form::get_payment_agent_registration_form({
        loginid           => $loginid,
        broker            => $broker,
        coc_approval_time => $pa->code_of_conduct_approval_date,
        tiers             => _get_tiers($pa),
    });

    my $input_fields = _prepare_display_values($pa);

    $payment_agent_registration_form->set_input_fields($input_fields);

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
    my $old_status = $pa->status // '';

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

    my %args = map { MAP_FIELDS->{$_} => request()->param($_) } keys MAP_FIELDS->%*;
    for my $arg (qw/urls phone_numbers supported_payment_methods/) {
        my $main_attr = $pa->details_main_field->{$arg};
        $args{$arg} =~ s/^[\s\n]+|[\s\n]+$//g;
        $args{$arg} = [
            map {
                { $main_attr => $_ }
            } split '\n',
            $args{$arg}];
    }
    $args{$_} = ($args{$_} eq 'yes') for (qw/is_listed code_of_conduct_approval/);
    $args{currency_code} = $currency;

    $args{skip_coc_validation} = 1 if $editing;

    my ($is_pa_approved_before) = $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.paymentagent_approved_before_check(?)', undef, $loginid);
        }) if $args{status} eq 'authorized';

    try {
        %args = $pa->validate_payment_agent_details(%args)->%*;
        $pa->$_($args{$_}) for keys %args;
        $pa->save;

        if (my $affiliate_id = $pa->{affiliate_id}) {
            my $affiliate = $client->user->affiliate // {};
            if ($affiliate_id ne ($affiliate->{affiliate_id} // '')) {
                $client->user->set_affiliate_id($pa->{affiliate_id});
            }
        }

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

    code_exit_BO("Invalid Countries: could not add countries.")
        unless ($client->get_payment_agent->set_countries(\@countries));

    print "<p class='success'>Successfully updated payment agent details for [$encoded_loginid]</p><br/>";

    # $is_pa_approved_before will only be defined if $pa->status eq 'authorized' is TRUE
    # however, !$is_pa_approved_before is safe to use because to reach here, $pa->status eq 'authorized' must be TRUE first
    if ($pa->status eq 'authorized' && ($pa->status ne $old_status) && !$is_pa_approved_before) {
        my $brand   = request()->brand;
        my $lang    = $client->user->preferred_language // 'EN';
        my $tnc_url = $brand->tnc_approval_url({language => uc($lang)});

        BOM::Platform::Event::Emitter::emit(
            pa_first_time_approved => {
                loginid    => $loginid,
                properties => {
                    first_name    => $client->first_name,
                    contact_email => $brand->emails('pa_business'),
                    tnc_url       => $tnc_url,
                }});
    }

    my $pa_edit_href = request()->url_for(
        "backoffice/f_setting_paymentagent.cgi",
        {
            broker   => $broker,
            loginid  => $loginid,
            whattodo => 'show',
        });

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

    my $pa_list_href = request()->url_for(
        "backoffice/f_payment_agent_list.cgi",
        {
            broker => $broker,
        });

    print qq(<a class='link' href="$pa_edit_href">&laquo; Return to Payment Agent setting for $encoded_loginid<a/><br>);
    print qq(<a class='link' href="$auditt_href">&laquo; Show payment-agent audit trail for $encoded_loginid</a><br/>);
    print qq(<a class='link' href="$return_href">&laquo; Return to client details<a/><br>);
    print qq(<a class='link' href="$pa_list_href">&laquo; Payment Agent list<a/><br>);

    code_exit_BO();
}

1;

#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use List::Util qw(any);
use Log::Any::Adapter qw(Stdout), log_level => 'debug';
use Log::Any qw($log);
use Getopt::Long;
use Date::Utility;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::User;
use BOM::User::Password;
use BOM::User::Client;

=head1 Name

create_escrow_account - script for creating escrow account for landing companies.

=head1 Description

The script should be ran at production just one time to bootstrap escrow accounts
for all landing companies and all currencies.

All created accounts wil be added to p2p configuration as well.

=cut

GetOptions(
    'p|password=s' => \my $input_password,
);

my %config = (
    svg => {
        residence        => 'za',
        country_idd_code => 27
    },
    malta => {
        residence        => 'ie',
        country_idd_code => 353
    },
    iom => {
        residence        => 'gb',
        country_idd_code => 44
    },
    maltainvest => {
        residence                 => 'ie',
        country_idd_code          => 353,
        tax_identification_number => '111-222-333',
    },
);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

$log->infof('Escrow accounts current config is :  %s', $app_config->payments->p2p->escrow);

my $landing_company_registry = LandingCompany::Registry->new();

my @escrow_accounts = ();
foreach my $landing_company_short_name (keys %config) {
    my $landing_company = $landing_company_registry->get($landing_company_short_name)
        or die "Cannot create landing company from $landing_company_short_name";

    foreach my $currency (keys %{$landing_company->legal_allowed_currencies()}) {
        push @escrow_accounts,
            create_client(
            landing_company => $landing_company,
            currency        => $currency,
            );
    }
}

$app_config->set({'payments.p2p.escrow' => \@escrow_accounts});
$log->infof('Escrow accounts updated config is :  %s', $app_config->payments->p2p->escrow);

sub create_client {
    my (%args) = @_;

    my $landing_company = delete($args{landing_company}) or die 'need landing company';
    my $currency        = delete($args{currency})        or die 'need currency';
    my $password        = $input_password                or die 'need password';

    my $email = 'payments+escrow_' . $landing_company->short . '_' . lc($currency) . '@binary.com';
    my $landing_company_config = $config{$landing_company->short} or die "Config not defined for " . $landing_company->short;

    my $residence        = $landing_company_config->{residence}        or die 'need residence';
    my $country_idd_code = $landing_company_config->{country_idd_code} or die 'need country_idd_code';
    my $tax_identification_number = $landing_company_config->{tax_identification_number} // '';

    my $hashed_password = BOM::User::Password::hashpw($password);

    $log->infof('Creating user with email %s', $email);

    my $user = BOM::User->create(
        email              => $email,
        password           => $hashed_password,
        email_verified     => 1,
        has_social_signup  => 0,
        email_consent      => 1,
        app_id             => 1,
        date_first_contact => Date::Utility->today->date_yyyymmdd,
    );

    $log->infof('User %s', $user->id);

    my %details = (
        client_password    => $hashed_password,
        first_name         => '',
        last_name          => '',
        myaffiliates_token => '',
        email              => $email,
        residence          => $residence,
        address_line_1     => '',
        address_line_2     => '',
        address_city       => '',
        address_state      => '',
        address_postcode   => '',
        phone              => '',
        secret_question    => '',
        secret_answer      => '',
    );

    my $vr = $user->create_client(
        %details,
        broker_code => 'VRTC',
    );

    $vr->set_default_account('USD');
    $log->infof('Virtual account %s', $vr->loginid);
    $vr->save;

    my @randnum = ("0" .. "9");
    my $randnum;
    $randnum .= $randnum[rand @randnum] for 1 .. 8;

    $details{first_name}                = 'Escrow';
    $details{last_name}                 = lc($currency) . ' account for ' . $landing_company->short;
    $details{phone}                     = qq{+${country_idd_code}${randnum}};
    $details{tax_residence}             = $residence;
    $details{tax_identification_number} = $tax_identification_number;
    $details{account_opening_reason}    = 'Speculative';
    $details{date_of_birth}             = '1990-01-01';

    my $client = $user->create_client(
        %details,
        broker_code => $landing_company->broker_codes->[0],
    );

    $log->infof('Real account loginid: %s, currency: %s', $client->loginid, $currency);
    $client->set_default_account($currency);
    set_financial_assessment($client);
    $client->save;

    return $client->loginid;
}

sub financial_assessment_details {
    my %data = (
        "forex_trading_experience"             => "0-1 year",
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
        "binary_options_trading_experience"    => "0-1 year",
        "binary_options_trading_frequency"     => "0-5 transactions in the past 12 months",
        "cfd_trading_experience"               => "0-1 year",
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
        "other_instruments_trading_experience" => "0-1 year",
        "other_instruments_trading_frequency"  => "0-5 transactions in the past 12 months",
        "employment_industry"                  => "Health",
        "education_level"                      => "Secondary",
        "income_source"                        => "Self-Employed",
        "net_income"                           => '$25,000 - $50,000',
        "estimated_worth"                      => '$100,000 - $250,000',
        "occupation"                           => 'Managers',
        "employment_status"                    => "Self-Employed",
        "source_of_wealth"                     => "Company Ownership",
        "account_turnover"                     => 'Less than $25,000',
    );

    return encode_json_utf8(\%data);
}

sub set_financial_assessment {
    my $client = shift;
    $client->financial_assessment({data => financial_assessment_details()});
    $client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
}

1;

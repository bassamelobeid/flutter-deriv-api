package BOM::Test::Helper::Client;

use strict;
use warnings;

use Exporter qw( import );

use BOM::User::Client;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Password;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Database::ClientDB;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Platform::Token::API;
use BOM::Platform::Locale;

our @EXPORT_OK = qw( create_client top_up close_all_open_contracts);

#
# wrapper for BOM::Test::Data::Utility::UnitTestDatabase::create_client(
#
sub create_client {
    my $broker   = shift || 'CR';
    my $skipauth = shift;
    my $args     = shift;
    my $client   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => $broker,
            ($args ? %$args : ()),    # modification to default client info
        },
        $skipauth ? undef : 1
    );
    return $client;
}

sub top_up {
    my ($c, $cur, $amount, $payment_type) = @_;

    $payment_type //= 'ewallet';

    my $fdp = $c->is_first_deposit_pending;
    my $acc = $c->account($cur);

    # Define the transaction date here instead of use the now() as default in
    # postgres so we can mock the date.
    my $date = Date::Utility->new()->datetime_yyyymmdd_hhmmss;

    my ($trx) = $c->payment_legacy_payment(
        amount           => $amount,
        currency         => $cur,
        payment_type     => $payment_type,
        status           => "OK",
        staff_loginid    => "test",
        remark           => __FILE__ . ':' . __LINE__,
        payment_time     => $date,
        account_id       => $acc->id,
        transaction_time => $date
    );

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
    return;
}

=head2 create_doughflow_methods

Creates entries in the payment.doughflow_method table:

=over 4

=item * payment_processor = 'reversible', payment_method = '': reversible, withdrawal not supported

=item * payment_processor = 'nonreversible', payment_method = '': non reversible, withdrawal supported

=back

Takes the following argument:

=over 4

=item * C<broker> - uppercase broker code

=back

=cut

sub create_doughflow_methods {
    my $broker = shift;

    BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic->dbh->do(
        "INSERT INTO payment.doughflow_method (payment_processor, reversible, withdrawal_supported) 
        VALUES ('reversible', TRUE, FALSE), ('nonreversible', FALSE, TRUE)"
    );
}

=head2 create_wallet_factory

Creates User object and generator function for creating wallets accounts 

=cut 

my $user_counter = 0;

sub create_wallet_factory {
    my ($residence, $address_state) = @_;

    my $user = BOM::User->create(
        email          => 'test_email' . $user_counter++ . '@example.com',
        password       => BOM::User::Password::hashpw('Abcd3s3!@'),
        email_verified => 1
    );

    $residence //= 'id';
    unless ($address_state) {
        my $states = BOM::Platform::Locale::get_state_option($residence);
        $address_state = $states->[0]->{value} if $states;
    }

    my $wallet_generator = sub {
        my ($broker_code, $account_type, $currency) = @_;
        my $client = $user->create_wallet(
            broker_code               => $broker_code,
            account_type              => $account_type,
            email                     => $user->email,
            residence                 => $residence,
            last_name                 => 'Test' . rand(999),
            first_name                => 'Test1' . rand(999),
            date_of_birth             => '1987-09-04',
            address_line_1            => 'Sovetskaya street',
            address_city              => 'Samara',
            address_state             => $address_state,
            address_postcode          => '112233',
            secret_question           => '',
            secret_answer             => '',
            account_opening_reason    => 'Speculative',
            tax_residence             => $residence,
            tax_identification_number => '111-222-333',
            citizen                   => $residence,
            client_password           => BOM::User::Password::hashpw('Abcd3s3!@'),
            phone                     => '',
            non_pep_declaration_time  => DateTime->now,
            salutation                => 'Mr.',

        );
        $client->set_default_account($currency);

        if ($broker_code eq 'MFW') {
            fill_up_maltainvest_financial_assestment($client);
        }

        return $client, BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    };

    return $user, $wallet_generator;

}

=head2 fill_up_maltainvest_financial_assestment

Fills valid maltainvest financial assestment for provided client object

=cut 

sub fill_up_maltainvest_financial_assestment {
    my ($client) = @_;

    $client->financial_assessment({
            data => encode_json_utf8(
                +{
                    "risk_tolerance"                           => "Yes",
                    "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
                    "cfd_experience"                           => "Less than a year",
                    "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
                    "trading_experience_financial_instruments" => "Less than a year",
                    "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
                    "cfd_trading_definition"                   => "Speculate on the price movement.",
                    "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
                    "leverage_trading_high_risk_stop_loss"     =>
                        "Close your trade automatically when the loss is more than or equal to a specific amount.",
                    "required_initial_margin" => "When opening a Leveraged CFD trade.",
                    "employment_industry"     => "Finance",
                    "education_level"         => "Secondary",
                    "income_source"           => "Self-Employed",
                    "net_income"              => '$25,000 - $50,000',
                    "estimated_worth"         => '$100,000 - $250,000',
                    "account_turnover"        => '$25,000 - $50,000',
                    "occupation"              => 'Managers',
                    "employment_status"       => "Self-Employed",
                    "source_of_wealth"        => "Company Ownership",
                })});
    $client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $client->save();
}

1;

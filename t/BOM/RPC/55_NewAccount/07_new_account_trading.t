use strict;
use warnings;
use utf8;

no indirect;
use feature qw(state);

use Test::More;
use Test::Mojo;
use Test::Deep qw(cmp_deeply);
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Test::Fatal     qw(lives_ok);

use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

subtest 'It should be able to create trading account ' => sub {
    my $params = +{};

    my ($user, $add_wallet) = crete_test_user();

    (undef, $params->{token}) = $add_wallet->(doughflow => 'USD');

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    my $acc = BOM::User::Client->new({loginid => $result->{client_id}})->default_account;
    is(($acc ? $acc->currency_code : ''), 'USD', "It should have the same currency as wallet account");

    (undef, $params->{token}) = $add_wallet->(p2p => 'USD');
    $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    $acc    = BOM::User::Client->new({loginid => $result->{client_id}})->default_account;
    is(($acc ? $acc->currency_code : ''), 'USD', "It should have the same currency as wallet account");

    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to P2P wallet";

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should not allow to create duplicated trading account for the same wallet' => sub {
    my ($user, $add_wallet) = crete_test_user();

    my $params = +{};
    (undef, $params->{token}) = $add_wallet->(doughflow => 'USD');

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should not allow to create 2 trading accounts of the same type connected to different  wallet' => sub {
    my ($user, $add_wallet) = crete_test_user();

    my $params = +{};
    (undef, $params->{token}) = $add_wallet->(doughflow => 'USD');

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";

    (undef, $params->{token}) = $add_wallet->(p2p => 'USD');
    $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^CR\d+}, "It should create trading account attached to DF wallet";
};

subtest 'It should not allow to create 2 trading accounts for unsupported wallet types' => sub {
    my ($user, $add_wallet) = crete_test_user();

    my $params = +{};
    (undef, $params->{token}) = $add_wallet->(paymentagent => 'USD');

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should not allow to create 2 trading accounts for unsupported wallet types' => sub {
    my ($user, $add_wallet) = crete_test_user();

    my $params = +{};
    (undef, $params->{token}) = $add_wallet->(paymentagent => 'USD');

    $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_error->error_code_is("InvalidAccount", "It should fail duplicate check");
};

subtest 'It should be able to create trading account for maltainvest' => sub {
    my $params = +{};
    my ($user, $add_wallet) = crete_test_user('MFW');

    (undef, $params->{token}) = $add_wallet->(doughflow => 'USD');

    my $result = $rpc_ct->call_ok(new_account_real => $params)->has_no_system_error->has_no_error->result;
    like $result->{client_id}, qr{^MF\d+}, "It should create trading account attached to DF wallet";
};

sub crete_test_user {
    my $broker_code = shift // 'CRW';
    state $counter = 0;

    my $user = BOM::User->create(
        email          => 'trading_account_test' . $counter++ . '@binary.com',
        password       => BOM::User::Password::hashpw('Abcd3s3!@'),
        email_verified => 1
    );

    my $wallet_generator = sub {
        my ($account_type, $currency) = @_;
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code               => $broker_code,
            account_type              => $account_type,
            email                     => $user->email,
            residence                 => 'za',
            last_name                 => 'Test' . rand(999),
            first_name                => 'Test1' . rand(999),
            date_of_birth             => '1987-09-04',
            address_line_1            => 'Sovetskaya street',
            address_city              => 'Samara',
            address_state             => 'Gauteng',
            address_postcode          => '112233',
            secret_question           => '',
            secret_answer             => '',
            account_opening_reason    => 'Speculative',
            tax_residence             => 'es',
            tax_identification_number => '111-222-333',
            citizen                   => 'es',
        });
        $client->set_default_account($currency);

        if ($broker_code eq 'MFW') {
            $client->financial_assessment({
                    data => encode_json_utf8(
                        +{
                            "risk_tolerance"       => "Yes",
                            "source_of_experience" => "I have an academic degree, professional certification, and/or work experience.",
                            "cfd_experience"       => "Less than a year",
                            "cfd_frequency"        => "1 - 5 transactions in the past 12 months",
                            "trading_experience_financial_instruments" => "Less than a year",
                            "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
                            "cfd_trading_definition"                   => "Speculate on the price movement.",
                            "leverage_impact_trading"              => "Leverage lets you open larger positions for a fraction of the trade's value.",
                            "leverage_trading_high_risk_stop_loss" =>
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
        $user->add_client($client);
        return $client, BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    };

    return $user, $wallet_generator;

}

done_testing;

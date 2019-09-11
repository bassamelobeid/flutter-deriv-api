use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( top_up );
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Config::Runtime;
use Email::Stuffer::TestLinks;

use utf8;

# init test data

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('USD');

# make him a payment agent
$pa_client->payment_agent({
    payment_agent_name    => "Joe",
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    target_country        => 'id',
});
$pa_client->save;

my $first_pa_loginid = $pa_client->loginid;

$pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('BTC');

# make him a payment agent
$pa_client->payment_agent({
    payment_agent_name    => 'Hoe',
    url                   => 'http://www.sample.com/',
    email                 => 'hoe@sample.com',
    phone                 => '+12345678',
    information           => 'Test Information',
    summary               => 'Test Summary Another',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'BTC',
    target_country        => 'id',
});
$pa_client->save;
my $second_pa_loginid = $pa_client->loginid;

$pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->set_default_account('ETH');

# make him a payment agent
$pa_client->payment_agent({
    payment_agent_name    => "Test Перевод encoding<>!@#$%^&*'`\"",
    url                   => 'http://www.sample2.com/',
    email                 => 'test@sample.com',
    phone                 => '+12345678',
    information           => 'Test Information2',
    summary               => "Test ~!@#$%^&*()_+,.<>/?;:'\"[]{}",
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'ETH',
    target_country        => 'id',
});
$pa_client->save;
my $third_pa_loginid = $pa_client->loginid;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $method = 'paymentagent_list';

subtest 'paymentagent_list RPC call' => sub {
# start test
    my $params = {
        language => 'EN',
        token    => '12345',
        args     => {paymentagent_list => 'id'},
    };

    my $expected_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        'available_countries' => [['id', 'Indonesia',], ['', undef]],
        'list' => [{
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => 'Hoe',
                'further_information'   => 'Test Information',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'BTC',
                'email'                 => 'hoe@sample.com',
                'summary'               => 'Test Summary Another',
                'url'                   => 'http://www.sample.com/',
                'paymentagent_loginid'  => $second_pa_loginid,
                'max_withdrawal'        => 5,
                'min_withdrawal'        => 0.002,
            },
            {
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => "Joe",
                'further_information'   => 'Test Info',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'USD',
                'email'                 => 'joe@example.com',
                'summary'               => 'Test Summary',
                'url'                   => 'http://www.example.com/',
                'paymentagent_loginid'  => $first_pa_loginid,
                'max_withdrawal'        => 2000,
                'min_withdrawal'        => 10,
            },
            {
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => "Test Перевод encoding<>!@#$%^&*'`\"",
                'further_information'   => 'Test Information2',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'ETH',
                'email'                 => 'test@sample.com',
                'summary'               => "Test ~!@#$%^&*()_+,.<>/?;:'\"[]{}",
                'url'                   => 'http://www.sample2.com/',
                'paymentagent_loginid'  => $third_pa_loginid,
                'max_withdrawal'        => 5,
                'min_withdrawal'        => 0.002,
            }]};

    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($expected_result, 'If token is invalid, then the paymentagents are from broker "CR"');
    $params->{token} = $token;
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($expected_result, "If token is valid, then the paymentagents are from client's broker");

    $expected_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        'available_countries' => [['id', 'Indonesia',], ['', undef]],
        'list' => [{
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => 'Hoe',
                'further_information'   => 'Test Information',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'BTC',
                'email'                 => 'hoe@sample.com',
                'summary'               => 'Test Summary Another',
                'url'                   => 'http://www.sample.com/',
                'paymentagent_loginid'  => $second_pa_loginid,
                'max_withdrawal'        => 5,
                'min_withdrawal'        => 0.002,
            }]};

    $params->{args} = {
        paymentagent_list => 'id',
        "currency"        => "BTC"
    };

    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, "If currency is passed then it returns for that currency only");
};

subtest 'suspend countries' => sub {

    my $pa_info = {
        payment_agent_name    => 'Xoe',
        url                   => 'http://www.sample.com/',
        email                 => 'xoe@sample.com',
        phone                 => '+12345678',
        information           => 'Test Information',
        summary               => 'Test Summary Another',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        is_authenticated      => 't',
        currency_code         => 'USD',
        target_country        => 'af',
    };

    my $params = {
        language => 'EN',
        args     => {paymentagent_list => 'af'},
    };

    my $af_agent = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'af',
        place_of_birth => 'af',
    });
    $af_agent->set_default_account('USD');
    $af_agent->payment_agent($pa_info);
    $af_agent->save;
    my $token_agent = BOM::Database::Model::OAuth->new->store_access_token_only(1, $af_agent->loginid);

    my $af_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'af',
        place_of_birth => 'af',
    });
    $af_client->set_default_account('USD');
    $af_client->save;
    my $token_client = BOM::Database::Model::OAuth->new->store_access_token_only(1, $af_client->loginid);

    my $empty_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        'available_countries' => [['id', 'Indonesia',], ['', undef]],
        'list' => [],
    };

    my $full_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        'available_countries' => [['id', 'Indonesia',], ['af', 'Afghanistan',], ['', undef]],
        'list' => [{
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => 'Xoe',
                'further_information'   => 'Test Information',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'USD',
                'email'                 => 'xoe@sample.com',
                'summary'               => 'Test Summary Another',
                'url'                   => 'http://www.sample.com/',
                'paymentagent_loginid'  => $af_agent->loginid,
                'max_withdrawal'        => 2000,
                'min_withdrawal'        => 10,
            }
        ],
    };

    my $empty_plus_agent_result = {
        stash => {
            app_markup_percentage      => 0,
            valid_source               => 1,
            source_bypass_verification => 0
        },
        'available_countries' => [['id', 'Indonesia',], ['', undef]],
        'list' => [{
                'telephone'             => '+12345678',
                'supported_banks'       => undef,
                'name'                  => 'Xoe',
                'further_information'   => 'Test Information',
                'deposit_commission'    => '0',
                'withdrawal_commission' => '0',
                'currencies'            => 'USD',
                'email'                 => 'xoe@sample.com',
                'summary'               => 'Test Summary Another',
                'url'                   => 'http://www.sample.com/',
                'paymentagent_loginid'  => $af_agent->loginid,
                'max_withdrawal'        => 2000,
                'min_withdrawal'        => 10,
            }
        ],
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['us']);
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($full_result, "Result is the same for non-suspended countries.");

    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['af']);
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($empty_result, "Result of unauthenticated call is empty when target country is suspended.");

    $params->{token} = $token_client;
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($empty_result, "Result of client_authenticated call is empty when target country is suspended.");

    $params->{token} = $token_agent;
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($empty_plus_agent_result,
        "Result of agent-authenticated call contains agent itself, because FE needs it for extracting settings.");

    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
    top_up $af_agent, 'USD' => 100;
    my $transfer_params = {
        language => 'EN',
        token    => $token_agent,
        args     => {
            paymentagent_transfer => 1,
            transfer_to           => $af_client->loginid,
            currency              => "USD",
            amount                => 10
        },
    };
    $c->call_ok('paymentagent_transfer', $transfer_params)->has_no_error;
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['af']);

    delete $params->{token};
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($empty_result, "Result of unauthenticated call is still empty after country is suspended.");

    $params->{token} = $token_client;
    $c->call_ok($method, $params)
        ->has_no_error->result_is_deeply($empty_plus_agent_result,
        "Result of client-authenticated call includes the previously transfered pa, even when country is suspended.");

    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

    delete $params->{token};
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($full_result, "Result is reverted after target country is reset.");

};

# TODO:
# I want to test a client with broker 'MF', so the result should be empty. But I cannot, because seems all broker data are in one db on QA and travis
done_testing();

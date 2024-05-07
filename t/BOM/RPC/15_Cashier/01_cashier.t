use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Email::Address::UseXS;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use LandingCompany::Registry;
use BOM::Test::Email                           qw(:no_event);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Utility                 qw(random_email_address);
use BOM::Test::Helper::Client                  qw( create_client top_up );
use BOM::Test::RPC::QueueClient;
use BOM::User;
use LWP::UserAgent;
require Test::NoWarnings;
use BOM::Platform::Token;

use BOM::Config::Redis;
use JSON::MaybeXS                    qw(encode_json decode_json);
use Format::Util::Numbers            qw/financialrounding/;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
populate_exchange_rates();

# this must be declared at the end, otherwise BOM::Test::Email will fail
use Test::Most;

my $mocked_call = Test::MockModule->new('LWP::UserAgent');

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $email          = random_email_address;
my $user_client_cr = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
});
$client_cr->set_default_account('USD');

$user_client_cr->add_client($client_cr);

subtest 'Doughflow' => sub {
    my $params = {};
    $params->{args}->{cashier} = 'deposit';
    $params->{token}           = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token123');
    $params->{domain}          = 'binary.com';

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/frontend not found/, 'No frontend error');

    $mocked_call->mock('post', sub { return {_content => 'customer too old'} });

    mailbox_clear();

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/customer too old/, 'Customer too old error')
        ->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    my $msg = mailbox_search(subject => qr/DOUGHFLOW_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/over 110 years old/, "Correct message to too old";

    $mocked_call->mock('post', sub { return {_content => 'customer underage'} });

    mailbox_clear();

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_internal_message_like(qr/customer underage/, 'Customer underage error')->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    $msg = mailbox_search(subject => qr/DOUGHFLOW_MIN_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/under 18 years/, "Correct message to underage";

    $mocked_call->mock('post', sub { return {_content => 'abcdef'} });

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/abcdef/, 'Unknown Doughflow error')
        ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.', 'Correct Unknown Doughflow error message');

    $mocked_call->mock('post', sub { return {_content => 'OK'} });
    ok !$client_cr->status->deposit_attempt, 'The deposit_attempt status has not been set';
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_no_error->result;
    $client_cr->status->_build_all;    # reload status
    ok $client_cr->status->deposit_attempt, 'Attempted a deposit';

    $params->{args} = {set_account_currency => 'GBP'};
    $rpc_ct->call_ok('set_account_currency', $params)->error_message_is('Change of currency is not allowed after the first deposit attempt.',
        'Expected error trying to set currency on a flagged account');

    # Now we have a deposit
    $client_cr->payment_doughflow(
        currency => 'USD',
        amount   => '15',
        remark   => '{"example": "remark"}'
    );
    # and simulate bom-paymentapi clearing
    $client_cr->status->clear_deposit_attempt;

    $client_cr->status->_build_all;
    ok !$client_cr->status->deposit_attempt, 'The status deposit_attempt was removed';

    # Attempt a new deposit
    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_no_error->result;
    $client_cr->status->_build_all;
    ok !$client_cr->status->deposit_attempt, 'Once there is a deposit the deposit_attempt is not added anymore';
};

subtest 'Crypto cashier calls' => sub {
    my $new_email = random_email_address;
    my $user      = BOM::User->create(
        email          => $new_email,
        password       => BOM::User::Password::hashpw('somepasswd123'),
        email_verified => 1,
    );
    my $client_info = {
        broker_code    => 'CR',
        email          => $new_email,
        place_of_birth => 'id',
    };

    my $client_fiat = BOM::Test::Data::Utility::UnitTestDatabase::create_client({$client_info->%*});
    $user->add_client($client_fiat);

    my $fiat_params = {
        args   => {cashier_payments => 1},
        token  => BOM::Platform::Token::API->new->create_token($client_fiat->loginid, 'test token123'),
        domain => 'binary.com',
    };
    $rpc_ct->call_ok('cashier_payments', $fiat_params)->has_error->error_code_is('NoAccountCurrency', 'Correct error code when currency not set.')
        ->error_message_is('Please set the currency for your existing account.', 'Correct error message when currency not set.');

    $client_fiat->set_default_account('USD');

    my $client_crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({$client_info->%*});
    $client_crypto->set_default_account('BTC');
    $user->add_client($client_crypto);

    my $token_fiat   = BOM::Platform::Token::API->new->create_token($client_fiat->loginid,   'test token');
    my $token_crypto = BOM::Platform::Token::API->new->create_token($client_crypto->loginid, 'test token');

    my $common_expected_result = {
        stash => {
            valid_source               => 1,
            app_markup_percentage      => 0,
            source_bypass_verification => 0,
            source_type                => 'official',
        },
    };

    my $calls = [{
            call_name    => 'cashier',
            call_display => 'cashier: deposit',
            args         => {
                cashier  => 'deposit',
                provider => 'crypto',
                type     => 'api',
            },
            api_response => {
                deposit_address => 'test_deposit_address',
            },
            rpc_response => {
                action  => 'deposit',
                deposit => {
                    address => 'test_deposit_address',
                },
            },
        },
        {
            call_name    => 'cashier',
            call_display => 'cashier: withdraw (dry-run)',
            args         => {
                cashier           => 'withdraw',
                provider          => 'crypto',
                type              => 'api',
                address           => 'withdrawal_address',
                amount            => 1,
                verification_code => 'verification_code',
                dry_run           => 1,
            },
            api_response => {
                dry_run => 1,
            },
            rpc_response => {
                action   => 'withdraw',
                withdraw => {
                    dry_run => 1,
                },
            },
        },
        {
            call_name    => 'cashier',
            call_display => 'cashier: withdraw',
            args         => {
                cashier           => 'withdraw',
                provider          => 'crypto',
                type              => 'api',
                address           => 'withdrawal_address',
                amount            => 1,
                verification_code => 'verification_code',
            },
            api_response => {
                id             => 1,
                status_code    => 'LOCKED',
                status_message => 'Sample status message',
            },
            rpc_response => {
                action   => 'withdraw',
                withdraw => {
                    id             => 1,
                    status_code    => 'LOCKED',
                    status_message => 'Sample status message',
                },
            },
        },
        {
            call_name => 'cashier_withdrawal_cancel',
            args      => {
                cashier_withdrawal_cancel => 1,
                id                        => 2,
            },
            api_response => {
                id          => 2,
                status_code => 'CANCELLED',
            },
        },
        {
            call_name => 'cashier_payments',
            args      => {
                cashier_payments => 1,
                provider         => 'crypto',
                transaction_type => 'all',
            },
            api_response => {
                crypto => [],
            },
        },
    ];

    my $api_error_response = {
        error => {
            code    => 'CryptoSampleErrorCode',
            message => 'Sample error message',
        }};
    my $fiat_error_response = {
        error => {
            code    => 'InvalidRequest',
            message => 'Crypto cashier is unavailable for fiat currencies.',
        }};

    my $api_response  = {};
    my $http_response = HTTP::Response->new(200);
    $mocked_call->mock($_ => sub { $http_response->content(encode_json_utf8($api_response)); $http_response; }) for qw(get post);

    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    $mock_utility->mock(is_verification_token_valid => sub { +{status => 1} });

    my $mock_CashierValidation = Test::MockModule->new('BOM::Platform::Client::CashierValidation');
    $mock_CashierValidation->mock(validate_crypto_withdrawal_request => sub { return; });

    for my $call_info ($calls->@*) {
        $api_response = {$call_info->{api_response}->%*};
        my $rpc_response = {($call_info->{rpc_response} // $api_response)->%*};
        my $params       = {args => $call_info->{args}};
        my $call_name    = $call_info->{call_name};
        my $call_display = $call_info->{call_display} // $call_name;

        $params->{token} = $token_fiat;
        my $expected_result = {$common_expected_result->%*, $fiat_error_response->%*};
        $rpc_ct->call_ok($call_name, $params)->has_no_system_error->has_error->error_code_is($fiat_error_response->{error}{code},
            "Correct error code when fiat account used for $call_display")
            ->error_message_is($fiat_error_response->{error}{message}, "Correct error message when fiat account used for $call_display");

        $params->{token} = $token_crypto;
        $expected_result = {$common_expected_result->%*, $rpc_response->%*};
        $rpc_ct->call_ok($call_name, $params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "Correct response for $call_display");

        $api_response    = $api_error_response;
        $expected_result = {$common_expected_result->%*, $api_error_response->%*};
        $rpc_ct->call_ok($call_name, $params)
            ->has_no_system_error->has_error->error_code_is($api_error_response->{error}{code}, "Correct error code for $call_display")
            ->error_message_is($api_error_response->{error}{message}, "Correct error message for $call_display");
    }

    $mock_utility->unmock_all;
    $mock_CashierValidation->unmock_all;
    $mocked_call->unmock_all;
};

subtest 'Crypto URL params' => sub {
    my $params = {
        source   => 1234,
        domain   => 'test-domain.com',
        brand    => 'test_brand',
        language => 'FR',
        app_id   => undef,
        l        => undef,
    };
    # Since some parameters are not available in RPC, we need to make sure that
    # we pass them to the API with the value of their corresponding param as below
    my %mapping = (
        app_id => 'source',
        l      => 'language',
    );

    my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
    my $url            = $crypto_service->create_url('DEPOSIT');

    for my $key (keys $params->%*) {
        my $value = $params->{$key} // $params->{$mapping{$key}};
        like $url, qr/$key=$value/, "Value of '$key' is correct.";
    }
};

subtest 'validate_amount' => sub {
    my $mocked_fun = Test::MockModule->new('Format::Util::Numbers');
    $mocked_fun->mock('get_precision_config', sub { return {amount => {'BBB' => 5}} });
    is(BOM::RPC::v3::Cashier::validate_amount(0.00001, 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1e-05,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('1e-05', 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('fred',  'BBB'), 'Invalid amount.', 'Invalid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(0.001,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1,       'BBB'), undef,             'Valid Amount');
    is(
        BOM::RPC::v3::Cashier::validate_amount(0.000001, 'BBB'),
        'Invalid amount. Amount provided can not have more than 5 decimal places.',
        'Too many decimals'
    );
};

subtest 'api crypto_config' => sub {
    my $new_client       = create_client('CR', undef, {residence => 'id'});
    my $invalid_currency = "abcd";
    $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            args     => {
                crypto_config => 1,
                currency_code => $invalid_currency
            }}
    )->has_no_system_error->has_error->error_code_is("CryptoInvalidCurrency", "Correct error code when invalid currency code is provided")
        ->error_message_is("The provided currency $invalid_currency is not a valid cryptocurrency.",
        "Correct error message when invalid currency code is provided");

    my $redis_read = BOM::Config::Redis::redis_replicated_read();

    my $redis_result = $redis_read->get("rpc::cryptocurrency::crypto_config::");
    is undef, $redis_result, "should not have cache result prior any call to api.";
    my $client_locked_min_withdrawal = $redis_read->get("rpc::cryptocurrency::crypto_config::client_min_amount::" . $new_client->loginid);
    is undef, $client_locked_min_withdrawal, "does not contain locked amount prior to any call to api";

    $mocked_call->mock('get', sub { return {_content => 'customer too old'} });
    my $eth_min_withdrawal = 0.23;
    my $api_response       = {
        currencies_config => {
            BTC => {minimum_withdrawal => 0.00084364},
            ETH => {minimum_withdrawal => $eth_min_withdrawal},
        },
    };
    my $http_response = HTTP::Response->new(200);
    $mocked_call->mock(get => sub { $http_response->content(encode_json_utf8($api_response)); $http_response; });

    my $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            args     => {crypto_config => 1}})->has_no_system_error->has_no_error->result;

    $redis_result                 = decode_json($redis_read->get("rpc::cryptocurrency::crypto_config"));
    $client_locked_min_withdrawal = $redis_read->get("rpc::cryptocurrency::crypto_config::client_min_amount::" . $new_client->loginid);
    is undef, $client_locked_min_withdrawal, "does not contain locked min withdrawal amount as token was not passed";
    my $common_expected_result = {
        stash => {
            valid_source               => 1,
            app_markup_percentage      => 0,
            source_bypass_verification => 0,
            source_type                => 'official',
        },
    };
    my $expected_result = {$common_expected_result->%*, $redis_result->%*};

    cmp_deeply $result_api, $expected_result, 'Result matches with redis result as expected.';

    $api_response = {
        currencies_config => {
            BTC => {minimum_withdrawal => 0.00084364},
        },
    };

    $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            args     => {
                crypto_config => 1,
                currency_code => "BTC",
            }})->has_no_system_error->has_no_error->result;

    $redis_result = decode_json($redis_read->get("rpc::cryptocurrency::crypto_config::BTC"));

    $expected_result = {$common_expected_result->%*, $redis_result->%*};
    cmp_deeply $result_api, $expected_result, 'Result matches with redis result as expected when currency code is passed.';

    my $redis_write = BOM::Config::Redis::redis_replicated_write();
    $redis_write->del("rpc::cryptocurrency::crypto_config");

    $api_response = {
        currencies_config => {},
    };

    $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            args     => {
                crypto_config => 1,
            },
        })->has_no_system_error->has_no_error->result;

    $redis_result    = decode_json($redis_read->get("rpc::cryptocurrency::crypto_config"));
    $expected_result = {$common_expected_result->%*, $redis_result->%*};
    cmp_deeply $result_api, $expected_result, 'Correct result when empty hash is returned from crypto api for crypto configs.';

    $redis_write->del("rpc::cryptocurrency::crypto_config");
    my $m = BOM::Platform::Token::API->new;
    $new_client->set_default_account('ETH');
    my $token = $m->create_token($new_client->loginid, 'test token');

    $api_response = {
        currencies_config => {
            BTC => {minimum_withdrawal => 0.00084364},
            ETH => {minimum_withdrawal => $eth_min_withdrawal},
        },
    };
    $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            token    => $token,
            args     => {crypto_config => 1}})->has_no_system_error->has_no_error->result;
    $redis_result                 = decode_json($redis_read->get("rpc::cryptocurrency::crypto_config"));
    $client_locked_min_withdrawal = $redis_read->get("rpc::cryptocurrency::crypto_config::client_min_amount::" . $new_client->loginid);
    is $eth_min_withdrawal, $client_locked_min_withdrawal, "correct locked min withdrawal amount for client";
    # RPC crypto config expires
    $redis_write->del("rpc::cryptocurrency::crypto_config");
    # min withdrawal amount for ETH increased to 10
    $api_response = {
        currencies_config => {
            BTC => {minimum_withdrawal => 0.00084364},
            ETH => {minimum_withdrawal => 10},
        },
    };
    $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            args     => {
                crypto_config => 1,
            },
        })->has_no_system_error->has_no_error->result;
    # client access the withdrawal page again or iframe refreshed
    $result_api = $rpc_ct->call_ok(
        'crypto_config',
        {
            language => 'EN',
            token    => $token,
            args     => {crypto_config => 1}})->has_no_system_error->has_no_error->result;
    $redis_result                 = decode_json($redis_read->get("rpc::cryptocurrency::crypto_config"));
    $client_locked_min_withdrawal = $redis_read->get("rpc::cryptocurrency::crypto_config::client_min_amount::" . $new_client->loginid);
    $redis_result->{currencies_config}->{$new_client->currency}->{minimum_withdrawal} = $client_locked_min_withdrawal;
    $expected_result = {$common_expected_result->%*, $redis_result->%*};
    cmp_deeply $result_api, $expected_result, 'Correct result as locked min withdrawal amount feched from redis & used in api response';
    is $eth_min_withdrawal, $client_locked_min_withdrawal, "correct locked min withdrawal amount for client";

    $mocked_call->unmock_all;
};

subtest 'Crypto withdrawal API initial validations' => sub {
    my $new_email = random_email_address;

    my $user = BOM::User->create(
        email          => $new_email,
        password       => BOM::User::Password::hashpw('test'),
        email_verified => 1,
    );

    my $btc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $new_email,
        residence   => 'BR'
    });
    $btc_client->account('BTC');
    $user->add_client($btc_client);

    top_up $btc_client, 'BTC', 10;

    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    $mock_utility->mock(is_verification_token_valid => sub { +{status => 1} });

    my $args = {
        cashier           => 'withdraw',
        provider          => 'crypto',
        type              => 'api',
        address           => 'withdrawal_address',
        amount            => 20,
        verification_code => 'verification_code',
    };

    my $params = {
        language => 'EN',
        source   => 1,
        args     => $args,
        token    => BOM::Platform::Token::API->new->create_token($btc_client->loginid, 'test token')};

    my $expected_api_error_response = {
        error => {
            code    => 'CryptoWithdrawalBalanceExceeded',
            message => 'Withdrawal amount of ' . $args->{amount} . ' BTC exceeds your account balance of ' . $btc_client->account->balance . ' BTC.',
        }};

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is($expected_api_error_response->{error}{code},
        "Correct error code for withdrawal balance exceeds")
        ->error_message_is($expected_api_error_response->{error}{message}, "Correct error message for withdrawal balance exceeds");

    $args->{amount} = 2;

    my $mock_CashierValidation = Test::MockModule->new('BOM::Platform::Client::CashierValidation');
    $mock_CashierValidation->mock(
        get_restricted_countries => sub {
            return ['BR'];
        });

    my $mock_auth = Test::MockModule->new("BOM::User::Client");
    $mock_auth->mock(
        fully_authenticated => sub {
            return 0;
        });

    $expected_api_error_response = {
        error => {
            code    => 'CryptoWithdrawalNotAuthenticated',
            message => 'Please authenticate your account to proceed with withdrawals.',
        }};

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_code_is($expected_api_error_response->{error}{code},
        "Correct error code for checking if it's client's first deposit")
        ->error_message_is($expected_api_error_response->{error}{message}, "Correct error message for checking if it's client's first deposit");

    $mock_auth->unmock_all();
    $mock_utility->unmock_all();
    $mock_CashierValidation->unmock_all();

};

subtest 'wallets' => sub {

    $mocked_call->mock('post', sub { return {_content => 'OK'} });

    my $test_client_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CRW',
        account_type => 'doughflow',
        email        => 'wallet@test.com',
    });

    my $test_client_std = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CR',
        account_type => 'standard',
        email        => $test_client_crw->email,
    });

    my $wallet_user = BOM::User->create(
        email    => $test_client_crw->email,
        password => 'x',
    );

    $wallet_user->add_client($test_client_crw);
    $wallet_user->add_client($test_client_std);
    $test_client_crw->account('USD');
    $test_client_std->account('USD');
    $wallet_user->link_wallet_to_trading_account({wallet_id => $test_client_crw->loginid, client_id => $test_client_std->loginid});

    my $params = {
        language => 'EN',
        source   => 1,
        args     => {cashier => 'deposit'},
        token    => BOM::Platform::Token::API->new->create_token($test_client_crw->loginid, 'test token')};

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_no_error('CRW can access cashier');

    $params->{token} = BOM::Platform::Token::API->new->create_token($test_client_std->loginid, 'test token');

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error('CR standard cannot access cashier')
        ->error_code_is('CashierForwardError', 'correct error code')
        ->error_message_is('Cashier deposits and withdrawals are not allowed on this account.', 'correct error message');
};

done_testing();

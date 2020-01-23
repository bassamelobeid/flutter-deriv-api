use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Helper::Token;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $m = BOM::Platform::Token::API->new;

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'account_closure';
subtest 'account closure' => sub {
    my $args = {
        "account_closure" => 1,
        "reason"          => 'Financial concerns'
    };

    my $email = 'def456@email.com';

    # Create user
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my $new_client_handler = sub {
        my ($broker_code, $currency) = @_;
        $currency //= 'USD';

        my $new_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $broker_code});

        $new_client->set_default_account($currency);
        $new_client->email($email);
        $new_client->save;
        $user->add_client($new_client);

        return $new_client;
    };

    my $payment_handler = sub {
        my ($client, $amount) = @_;

        $client->payment_legacy_payment(
            currency     => $client->currency,
            amount       => $amount,
            remark       => 'testing',
            payment_type => 'ewallet'
        );

        return 1;
    };

    # Create VR client
    my $test_client_vr = $new_client_handler->('VRTC');

    # Create CR client (first)
    my $test_client = $new_client_handler->('CR');

    # Tokens

    my $token = $m->create_token($test_client->loginid, 'test token');

    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (no balance)
    # Test with virtual account
    is($res->{status}, 1, 'Successfully received request');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');

    $test_client_vr->status->clear_disabled;
    $test_client->status->clear_disabled;

    ok(!$test_client->status->disabled, 'CR account is enabled back again');

    subtest "Open Contracts" => sub {
        my $mock = Test::MockModule->new('BOM::User::Client');
        $mock->mock(
            get_open_contracts => sub {
                return [1];
            });

        $res = $c->tcall(
            $method,
            {
                token => $token,
                args  => $args
            });

        is($res->{error}->{code}, 'AccountHasOpenPositions', 'Correct error code');
        my $loginid = $test_client->loginid;
        is(
            $res->{error}->{message_to_client},
            "Please ensure all positions in your account(s) are closed before proceeding: $loginid.",
            "Correct error message"
        );
        is_deeply($res->{error}->{details}, {accounts => {$loginid => 1}}, "Correct error details");
        ok(!$test_client->status->disabled,    'CR account is not disabled');
        ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');

        $mock->unmock_all;
        $test_client_vr->status->clear_disabled;
        $test_client->status->clear_disabled;
    };

    $payment_handler->($test_client, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (balance)
    is($res->{error}->{code}, 'ExistingAccountHasBalance', 'Correct error code');
    ok(!$test_client->status->disabled,    'CR account is not disabled');
    ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');

    my $test_client_2 = $new_client_handler->('CR', 'BTC');
    $payment_handler->($test_client,   -1);
    $payment_handler->($test_client_2, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with real siblings account (balance)
    my $loginid = $test_client_2->loginid;
    is($res->{error}->{code}, 'ExistingAccountHasBalance', 'Correct error code');
    is(
        $res->{error}->{message_to_client},
        "Please withdraw all funds from your account(s) before proceeding: $loginid.",
        'Correct error message for sibling account'
    );
    is_deeply(
        $res->{error}->{details},
        {
            accounts => {
                $loginid => {
                    balance  => "1.00000000",
                    currency => 'BTC'
                }}
        },
        'Correct array in details'
    );
    is($test_client->account->balance, '0.00', 'CR (USD) has no balance');
    ok(!$test_client->status->disabled,   'CR account is not disabled');
    ok(!$test_client_2->status->disabled, 'Sibling account is also not disabled');

    # Test with siblings account (has balance)
    $payment_handler->($test_client_2, -1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    $test_client_vr = BOM::User::Client->new({loginid => $test_client_vr->loginid});
    $test_client    = BOM::User::Client->new({loginid => $test_client->loginid});
    $test_client_2  = BOM::User::Client->new({loginid => $test_client_2->loginid});

    my $disabled_hashref = $test_client_2->status->disabled;

    is($res->{status},                  1,                     'Successfully received request');
    is($disabled_hashref->{reason},     $args->{reason},       'Correct message for reason');
    is($disabled_hashref->{staff_name}, $test_client->loginid, 'Correct loginid');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');
};

done_testing();

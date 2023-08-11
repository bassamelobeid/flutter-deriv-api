use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $m       = BOM::Platform::Token::API->new;
my %DETAILS = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

subtest 'Payment Agent Account have trading rights disabled for REAL and enabled for DEMO servers' => sub {
    my $email     = $DETAILS{email};
    my $pa_client = create_client('CR', undef, {residence => 'id'});
    my $token     = $m->create_token($pa_client->loginid, 'test token');
    $pa_client->set_default_account('USD');
    $pa_client->email($email);

    my $user = BOM::User->create(
        email    => $email,
        password => 'Abcd1234',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($pa_client);

    my $object_pa = $pa_client->payment_agent({
        payment_agent_name    => 'Test Name',
        email                 => 'test@example.com',
        information           => 'Test Information',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $pa_client->save;

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };

    my $mt5_args;
    my $mt5_mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mt5_mock->mock(
        'create_user',
        sub {
            ($mt5_args) = @_;
            return $mt5_mock->original('create_user')->(@_);
        });

    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming';
    is $mt5_args->{rights}, '485', 'Expected user rights';

    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('demo account successfully created')->result;
    is $result->{account_type}, 'demo';
    is $mt5_args->{rights}, '481', 'Expected user rights';

};

subtest 'new mt5 account real and demo should have trading right disabled' => sub {
    my $client = create_client('CR', undef, {residence => 'id'});
    $client->set_default_account('USD');

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'Abcd1234',
    )->add_client($client);
    $user->update_trading_password($DETAILS{password}{main});

    my $token = $m->create_token($client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $DETAILS{email},
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };

    my $mt5_args;
    my $mt5_mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mt5_mock->mock(
        'create_user',
        sub {
            ($mt5_args) = @_;
            return $mt5_mock->original('create_user')->(@_);
        });

    # 485 will have 'USER_RIGHT_ENABLED | USER_RIGHT_TRAILING | USER_RIGHT_EXPERT | USER_RIGHT_API | USER_RIGHT_REPORTS | USER_RIGHT_TRADE_DISABLED'
    my $result = $c->call_ok($method, $params)->has_no_error('mt5 real account created successfully')->result;
    is $mt5_args->{rights}, '485', 'New MT5 real account should have trading disabled upon creation';

    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('mt5 demo account created successfully')->result;
    is $result->{account_type}, 'demo';
    is $mt5_args->{rights}, '485', 'New MT5 demo account should have trading disabled upon creation';
};

done_testing();

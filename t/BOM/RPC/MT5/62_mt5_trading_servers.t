#!/usr/bin/perl

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

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

subtest 'trading servers for south africa' => sub {
    my $new_email  = 'abcdef' . $DETAILS{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $m          = BOM::Platform::Token::API->new;
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);

    my $method = 'trading_servers';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'mt5',
            account_type => 'real',
            market_type  => 'synthetic',
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('returns all synthetic servers for real')->result;

    ok @$result == 4, 'returns 4 trade servers';

    is $result->[0]->{id}, 'p01_ts02', 'first server p01_ts02';
    is $result->[1]->{id}, 'p02_ts02', 'first server p02_ts02';
    is $result->[2]->{id}, 'p01_ts03', 'first server p01_ts03';
    is $result->[3]->{id}, 'p01_ts04', 'first server p01_ts04';

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
    my $new_account_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };
    $result = $c->call_ok('mt5_new_account', $new_account_params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming', 'account_type=gaming';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'}, 'created in group real\p01_ts02\synthetic\svg_std_usd\01';

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);

    $result =
        $c->call_ok($method, $params)->has_no_error('returns all synthetic servers for real except p01_ts02 or p02_ts01 (since routing is random)')
        ->result;

    ok @$result == 4, 'returns 4 trade servers';
    is $result->[0]->{id},                'p01_ts02', 'first server p01_ts02';
    ok $result->[0]->{disabled},          'first server p01_ts02 is disabled';
    is $result->[0]->{message_to_client}, 'Region added', 'correct error message';
    is $result->[1]->{id},                'p02_ts02',     'first server p02_ts02';
    ok $result->[1]->{disabled},          'first server p01_ts02 is disabled';
    is $result->[1]->{message_to_client}, 'Temporarily unavailable', 'correct error message';
    is $result->[2]->{id},                'p01_ts03',                'first server p01_ts03';
    ok !$result->[2]->{disabled};
    is $result->[3]->{id}, 'p01_ts04', 'first server p01_ts04';
    ok !$result->[3]->{disabled};

    $params->{args}{market_type} = 'financial';
    $result = $c->call_ok($method, $params)->has_no_error('returns all financial servers for real')->result;

    ok @$result == 1, 'retusn 1 trade server';
    is $result->[0]->{id},          'p01_ts01',     'server id is p01_ts01';
    is $result->[0]->{environment}, 'Deriv-Server', 'on Deriv-Server environment';
};

done_testing();

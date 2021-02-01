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

subtest 'country=za; creates financial account with existing gaming account while real02 disabled' => sub {
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
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
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
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real02->all(0);
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming', 'account_type=gaming';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real02\synthetic\svg_std_usd'}, 'created in group real02\synthetic\svg_std_usd';

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    my $financial = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
    is $financial->{account_type}, 'financial', 'account_type=financial';
    is $financial->{login}, 'MTR' . $ACCOUNTS{'real01\financial\svg_std_usd'}, 'created in group real01\financial\svg_std_usd';
    note('then call mt5 login list');
    $method = 'mt5_login_list';
    $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    note("disable real02 API calls.");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real02->all(1);
    my $login_list = $c->call_ok($method, $params)->has_no_error('has no error for mt5_login_list')->result;
    ok scalar(@$login_list) == 2, 'two accounts';
    is $login_list->[0]->{account_type}, 'real';
    is $login_list->[0]->{group},        'real01\financial\svg_std_usd';
    is $login_list->[0]->{login},        'MTR' . $ACCOUNTS{'real01\financial\svg_std_usd'};
    # second account inaccessible because API call is disabled
    ok $login_list->[1]->{error}, 'inaccessible account shows error';
    is $login_list->[1]->{error}{details}{login}, 'MTR' . $ACCOUNTS{'real02\synthetic\svg_std_usd'};
    is $login_list->[1]->{error}{message_to_client}, 'MT5 is currently unavailable. Please try again later.';
};

done_testing();

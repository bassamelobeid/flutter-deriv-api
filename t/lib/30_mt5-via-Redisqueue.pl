#!/usr/bin/perl

# To run this test and observe the Redis queue-based RPC mechanism at work,
# you will have to start another shell to your QA box and run the RPC worker.
#
#  $ cd .../bom-rpc
#  $ perl bin/binary_jobqueue_worker.pl --test
#
# the worker will run as a foreground process, printing details of incoming RPC
# requests and results of them to STDERR.
#
# Once started, you can run this test by simply
#
# prove t/BOM/RPC/30_mt5-via-Redisqueue.pl

use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::User;
use BOM::MT5::User::Async;

# TODO(leonerd): should have been present
use BOM::Database::Model::AccessToken;
use BOM::RPC::v3::MT5::Account;
# END TODO

use JSON::MaybeXS;
use IO::Async::Loop;
use Job::Async;

my $json = JSON::MaybeXS->new;

my $loop = IO::Async::Loop->new;
$loop->add(my $jobman = Job::Async->new);

my $client = $jobman->client(
    redis => {
        uri => 'redis://127.0.0.1',
    });
$client->start->get;

my $c = BOM::Test::RedisQueue::Client->new(client => $client);

# Mocked account details
# This hash shared between three files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/BOM/RPC/05_accounts.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '123454321',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\svg',
    country  => 'Malta',
    balance  => '1234.56',
);

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_authentication('ID_DOCUMENT')->status('pass');
$test_client->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_client->loginid, 'test token');

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    is($c->result->{login}, $DETAILS{login}, 'result->{login}');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');
};

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $DETAILS{login},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   $DETAILS{login},   'result->{login}');
    is($c->result->{balance}, $DETAILS{balance}, 'result->{balance}');
    is($c->result->{country}, "mt",              'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_get_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_get_settings wrong login');
};

subtest 'login list' => sub {
    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');
    is_deeply(
        $c->result,
        [{
                login => $DETAILS{login},
                group => $DETAILS{group}}
        ],
        'mt5_login_list result'
    );
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $DETAILS{login},
            password => $DETAILS{password},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_code_is('MT5PasswordCheckError', 'error code for mt5_password_check wrong password');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'password change' => sub {
    my $method = 'mt5_password_change';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login        => $DETAILS{login},
            old_password => $DETAILS{password},
            new_password => 'Ijkl6789',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_change wrong login');
};

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $test_client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 150,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    # TODO(leonerd): assert that account balance is now 1000-150 = 850

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $test_client->loginid,
            amount    => 150,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');
};

subtest 'mt5 mamm' => sub {
    my $method = "mt5_mamm";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $DETAILS{login},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_mamm');
    my $result = $c->result;
    is $result->{status},     1,  'Request was successful';
    is $result->{manager_id}, '', 'No manager assigned';
};

done_testing();

package BOM::Test::RedisQueue::Client;
# TODO: make B:T:R:C an abstraction
use base qw( BOM::Test::RPC::Client );

sub new {
    my $class = shift;
    my %args  = @_;

    my $client = delete $args{client};

    # We don't use UA but can't be bothered right now to abstract this out properly
    my $self = $class->SUPER::new(%args, ua => undef);

    $self->{client} = $client;

    return $self;
}

sub _tcall {
    my $self = shift;
    my ($method, $req_params) = @_;

    $self->params([$method, $req_params]);

    my $raw_response = $self->{client}->submit(
        name   => $method,
        id     => Data::UUID->new()->create_str(),
        params => $json->encode($req_params),
    )->get;

    my $response = $json->decode($raw_response);

    $self->response($response);    # ???
    $self->result($response->{result} // {});

    return $response;
}

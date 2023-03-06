use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Test::MockModule;
use APIHelper       qw(balance deposit_validate deposit update_payout);
use JSON::MaybeUTF8 qw(:v1);

my $loginid = 'CR0011';

my $client_db = BOM::Database::ClientDB->new({client_loginid => $loginid});

my $user = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda'
);
$user->add_loginid($loginid);

my $starting_balance = balance($loginid);

my $r = deposit_validate(
    loginid => $loginid,
);
is($r->code,                                 200,                   'correct status code');
is(decode_json_utf8($r->content)->{allowed}, 1,                     'validate pass');
is(0 + balance($loginid),                    $starting_balance + 0, 'balance is not changed.');

$r = deposit_validate(
    loginid => $loginid,
    amount  => 'Zzz',
);
my $resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'failed status';
like $resp->{message}, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message on response body';

subtest 'cashier validation' => sub {
    BOM::User::Client->new({loginid => $loginid})->status->set('cashier_locked', 'system', 'testing');

    my $req = deposit_validate(
        loginid => $loginid,
    );

    my $resp = decode_json_utf8($req->content);
    is $resp->{allowed}, 0,                         'validation fails when cashier_locked';
    is $resp->{message}, 'Your cashier is locked.', 'Correct error message in response body';
};

subtest 'graceful suspend payments' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful(1);
    BOM::Config::Runtime->instance->app_config->system->suspend->cashier(1);

    my $email = 'graceful_test@deriv.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'Pa$$w0rD'
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        binary_user_id => $user->id,
        broker_code    => 'CR',
        email          => $email,
        residence      => 'id',
    });
    $user->add_loginid($client->loginid);

    my $req = deposit_validate(
        loginid => $client->loginid,
    );

    my $resp = decode_json_utf8($req->content);
    is $resp->{allowed}, 0, 'Deposit validation fails when cashier and payments_graceful suspend';
    is $resp->{message}, 'The cashier is under maintenance, it will be back soon.', 'Correct error message in response body';

    my $balance = balance($client->loginid);
    my $r       = deposit(
        loginid => $client->loginid,
        amount  => 4
    );
    is 0 + balance($client->loginid), 4,         'Deposit passed balance changed';
    is $r->code,                      201,       'Correct status code';
    is $r->message,                   'Created', 'Correct message';

    $r = update_payout(
        loginid  => $client->loginid,
        status   => 'inprogress',
        trace_id => '101',
    );

    is($r->code,    200,  'Correct status code when cashier and payments_graceful is suspended');
    is($r->message, 'OK', 'Correct message when cashier and payments_graceful is suspended');
    like($r->content, qr[description="success"\s+status="0"], 'Correct content when cashier and payments_graceful is suspended');

    BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful(0);
    BOM::Config::Runtime->instance->app_config->system->suspend->cashier(0);
};

done_testing();

use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper                                  qw(balance deposit withdrawal_validate update_payout create_payout);
use JSON::MaybeUTF8                            qw(:v1);
use BOM::User::Client;
use Test::MockModule;

my $email = 'unit_test@binary.com';
my $cli   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
});
my $user = BOM::User->create(
    email    => $email,
    password => 'asdaiasda'
);
$user->add_client($cli);

my $loginid = $cli->loginid;

my $mock_account = Test::MockModule->new('BOM::User::Client::Account');
$mock_account->mock('total_withdrawals', sub { return 54321 });

my $r = deposit(loginid => $loginid);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
my $starting_balance = balance($loginid);

$r = withdrawal_validate(
    loginid => $loginid,
);
is($r->code, 200, 'correct status code');
my $resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/reached the maximum withdrawal limit/;
$mock_account->unmock('total_withdrawals');

$r = withdrawal_validate(
    loginid => $loginid,
);
is($r->code,                                 200,                   'correct status code');
is(decode_json_utf8($r->content)->{allowed}, 1,                     'validate pass');
is(0 + balance($loginid),                    $starting_balance + 0, 'Correct final balance');

$r = withdrawal_validate(
    loginid => $loginid,
    amount  => 'Zzz',
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message';

my $balance_now = balance($loginid);
$r = withdrawal_validate(
    loginid => $loginid,
    amount  => $balance_now + 1,
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/exceeds client balance/, "$balance_now plus 1 exceeds balance now";

# < 0.01 or > 100000
$r = withdrawal_validate(
    loginid => $loginid,
    amount  => 0.009,
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/Invalid money amount/, ".. bad little amount rejected helpfully";

$r = withdrawal_validate(
    loginid => $loginid,
    amount  => 100001,
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/Invalid money amount/, ".. bad big amount rejected helpfully";

subtest 'free gift' => sub {

    my $email  = 'promotest@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id',
    });
    BOM::User->create(
        email    => $email,
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    $client->db->dbic->dbh->do(
        q/insert into betonmarkets.promo_code (code, promo_code_type, promo_code_config, start_date, expiry_date, status, description) 
        values ('PROMO1','FREE_BET','{"country":"ALL","amount":"100","currency":"ALL"}', now() - interval '1 month', now() + interval '1 month','t','test') /
    );

    $client->promo_code('PROMO1');
    $client->promo_code_status('CLAIM');
    $client->save;

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 100,
        remark   => 'Free gift',
    );

    $r = withdrawal_validate(
        loginid => $client->loginid,
        amount  => 10,
    );
    my $resp = decode_json_utf8($r->content);
    is $resp->{allowed}, 0, 'validation failed';
    like $resp->{message}, qr/includes frozen bonus/, 'frozen bonus message';

    $r = update_payout(
        status  => 'inprogress',
        loginid => $client->loginid,
        amount  => 10,
    );
    is $r->code, 403, 'truly cannot withdraw!';
};

subtest 'graceful suspend payments' => sub {
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
    my $balance = balance($client->loginid);

    BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful(1);
    BOM::Config::Runtime->instance->app_config->system->suspend->cashier(1);

    my $req = withdrawal_validate(
        loginid => $client->loginid,
    );
    is($req->code, 200, 'correct status code');
    my $resp = decode_json_utf8($req->content);
    is $resp->{allowed},              0, 'Withdrawal validation fails when cashier and payments_graceful suspend';
    is $resp->{message},              'The cashier is under maintenance, it will be back soon.', 'Correct error message in response body';
    is 0 + balance($client->loginid), $balance + 0,                                              'Correct error message in response body';

    $req = create_payout(
        loginid => $client->loginid,
    );
    is($req->code,    403,         'Correct error status code when cashier and payments_graceful is suspended');
    is($req->message, 'Forbidden', 'Correct message when cashier and payments_graceful is suspended');
    like(
        $req->content,
        qr[error="The cashier is under maintenance, it will be back soon."],
        'Correct content when cashier and payments_graceful is suspended'
    );

    BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful(0);
    BOM::Config::Runtime->instance->app_config->system->suspend->cashier(0);
};

done_testing();

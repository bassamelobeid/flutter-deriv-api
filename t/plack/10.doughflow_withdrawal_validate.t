use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper qw(balance deposit withdraw);
use JSON::MaybeUTF8 qw(:v1);
use BOM::User::Client;

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

my $r = deposit(loginid => $loginid);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
my $starting_balance = balance($loginid);

$r = withdraw(
    loginid     => $loginid,
    is_validate => 1
);
is($r->code,                                200,                   'correct status code');
is(decode_json_utf8($r->content)->{allowed}, 1,                    'validate pass');
is(0 + balance($loginid),                   $starting_balance + 0, 'Correct final balance');

$r = withdraw(
    loginid     => $loginid,
    amount      => 'Zzz',
    is_validate => 1
);
my $resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message';

my $balance_now = balance($loginid);
$r = withdraw(
    loginid     => $loginid,
    amount      => $balance_now + 1,
    is_validate => 1
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/exceeds client balance/, "$balance_now plus 1 exceeds balance now";

# < 0.01 or > 100000
$r = withdraw(
    loginid     => $loginid,
    amount      => 0.009,
    is_validate => 1
);
$resp = decode_json_utf8($r->content);
is $resp->{allowed}, 0, 'validate failed';
like $resp->{message}, qr/Invalid money amount/, ".. bad little amount rejected helpfully";

$r = withdraw(
    loginid     => $loginid,
    amount      => 100001,
    is_validate => 1
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

    $r = withdraw(
        loginid     => $client->loginid,
        amount      => 10,
        is_validate => 1,
    );
    my $resp = decode_json_utf8($r->content);
    is $resp->{allowed}, 0, 'validation failed';
    like $resp->{message}, qr/includes frozen bonus/, 'frozen bonus message';

    $r = withdraw(
        loginid => $client->loginid,
        amount  => 10,
    );
    is $r->code, 403, 'truly cannot withdraw!';
};

done_testing();

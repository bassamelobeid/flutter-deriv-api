use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper                                  qw(balance deposit withdrawal_validate update_payout);
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

my $r = deposit(
    loginid => $loginid,
    amount  => 252.14
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');

my $starting_balance = balance($loginid);
is $starting_balance, 252.14, 'correct starting balance';

$r = withdrawal_validate(
    loginid => $loginid,
    amount  => 248.36,
    fee     => 3.78,
);

my $resp = decode_json_utf8($r->content);
is $resp->{allowed}, 1, 'validate passed';

$r = update_payout(
    status  => 'inprogress',
    loginid => $loginid,
    amount  => 248.36,
    fee     => 3.78,
);

is($r->code, 200, 'Correct code for floating number comparison');
like($r->decoded_content, qr/success/, 'Successful response for floating number comparison');

done_testing();

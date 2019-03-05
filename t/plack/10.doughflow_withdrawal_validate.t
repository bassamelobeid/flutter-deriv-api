use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit withdraw);
use JSON::MaybeUTF8 qw(:v1);
use BOM::User::Client;

my $loginid = 'CR0011';

my $cli = BOM::User::Client->new({loginid => $loginid});
$cli->place_of_birth('id');
$cli->save;

my $r = deposit(loginid => $loginid);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
my $starting_balance = balance($loginid);

$r = withdraw(
    loginid     => $loginid,
    is_validate => 1
);
is($r->code,                                 200,                   'correct status code');
is(decode_json_utf8($r->content)->{allowed}, 1,                     'validate pass');
is(0 + balance($loginid),                    $starting_balance + 0, 'Correct final balance');

$r = withdraw(
    loginid     => $loginid,
    amount      => 'Zzz',
    is_validate => 1
);
is($r->code, 400, 'Correct failure status code');
like($r->content, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message on response body');

my $balance_now = balance($loginid);
$r = withdraw(
    loginid     => $loginid,
    amount      => $balance_now + 1,
    is_validate => 1
);
is $r->code, 403, 'withdraw rejected';
like $r->decoded_content, qr/exceeds client balance/, "$balance_now plus 1 exceeds balance now";

# < 0.01 or > 100000
$r = withdraw(
    loginid     => $loginid,
    amount      => 0.009,
    is_validate => 1
);
is $r->code, 400, 'bad little amount rejected';
like $r->decoded_content, qr/Invalid money amount/, '.. bad little amount rejected helpfully';

$r = withdraw(
    loginid     => $loginid,
    amount      => 100001,
    is_validate => 1
);
is $r->code, 400, 'bad big amount rejected';
like $r->decoded_content, qr/Invalid money amount/, '.. bad big amount rejected helpfully';

done_testing();

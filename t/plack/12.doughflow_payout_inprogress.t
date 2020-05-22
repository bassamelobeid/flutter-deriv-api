use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit update_payout request decode_json);
use BOM::User::Client;

my $loginid = 'CR0011';

my $cli = BOM::User::Client->new({loginid => $loginid});
$cli->place_of_birth('id');
$cli->save;

my $user = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda'
);
$user->add_client($cli);
my $r = deposit(
    loginid => $loginid,
    amount  => 2
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');

my $starting_balance = balance($loginid);

$r = update_payout(
    loginid => $loginid,
    status  => 'inprogress'
);
is($r->code,    200,  'correct status code');
is($r->message, 'OK', 'Correct message');
like($r->content, qr[description="success"\s+status="0"], 'Correct content');

my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance - 1.00, 'Correct final balance');

# Failed tests
$r = update_payout(
    loginid  => $loginid,
    status   => 'inprogress',
    trace_id => ' 123'
);
is($r->code,    400,           'Correct failure status code');
is($r->message, 'Bad Request', 'Correct message');
like(
    $r->content,
    qr[(Attribute \(trace_id\) does not pass the type constraint|trace_id must be a positive integer)],
    'Correct error message on response body'
);
is(balance($loginid), $balance_now, 'Correct final balance (unchanged)');

# exceeds balance
$r = update_payout(
    loginid => $loginid,
    status  => 'inprogress',
    amount  => $balance_now + 1
);
is($r->code, 403, 'Error code for balance exceeded');
like($r->decoded_content, qr/exceeds client balance/, 'Message for balance exceeded');
is(balance($loginid), $balance_now, 'Correct final balance (unchanged)');

done_testing();

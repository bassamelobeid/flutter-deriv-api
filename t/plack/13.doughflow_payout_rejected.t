use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance update_payout deposit request decode_json);
use BOM::User::Client;
use BOM::User;

my $loginid = 'CR0012';

my $cli = BOM::User::Client->new({loginid => $loginid});
$cli->place_of_birth('id');
$cli->save;

my $user = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda'
);
$user->add_client($cli);
# deposit first so that we can withdraw
my $r = deposit(
    loginid => $loginid,
    amount  => 2
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
sleep 1;    # so the payment_time DESC for get_last_payment_of_account will be correct
my $starting_balance = balance($loginid);
ok($starting_balance >= 2);    # since we deposit 2

my $trace_id = time();
$r = update_payout(
    status   => 'inprogress',
    loginid  => $loginid,
    trace_id => $trace_id,
    amount   => 1
);
is($r->code,    200,  'correct status code');
is($r->message, 'OK', 'Correct message');
my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance - 1.00, 'Correct final balance');
ok($balance_now >= 1);
sleep 1;    # to make sure the trace_id is different

# try failed rejected
$r = update_payout(
    amount   => 1,
    loginid  => $loginid,
    status   => 'rejected',
    trace_id => time(),
);

is $r->code, 400, 'error code for bad trace_id';
like $r->decoded_content, qr/no corresponding original withdrawal could be found/, 'error message';
is 0+balance($loginid), 1, 'balance unchanged';

$r = update_payout(
    amount   => 0.5,
    loginid  => $loginid,
    status   => 'rejected',
    trace_id => $trace_id,
);

is $r->code, 400, 'error code for wrong amount';
like $r->decoded_content, qr/this does not match the original DoughFlow withdrawal request amount/, 'error message';
is 0+balance($loginid), 1, 'balance unchanged';     

$r = update_payout(
    amount   => 1,
    loginid  => $loginid,
    fee      => 1,
    status   => 'rejected',
    trace_id => $trace_id,
);
is $r->code, 400, 'error code for fee not allowed';
like $r->decoded_content, qr/Bonuses and fees are not allowed for withdrawal reversals/, 'erorr message';
is 0+balance($loginid), 1, 'balance unchanged';  

$r = update_payout(
    amount   => 1,
    loginid  => $loginid,
    status   => 'rejected',
    trace_id => $trace_id,
);

is $r->code, 200, 'valid withdrawal reversal';
is(0 + balance($loginid), 2, 'balance increased'); 

$r = update_payout(
    amount   => 1,
    loginid  => $loginid,
    status   => 'rejected',
    trace_id => $trace_id,
);

is $r->code, 400, 'error code for duplicate request';
like $r->decoded_content, qr/multiple corresponding original withdrawals were found/, 'error message';
is(0 + balance($loginid), 2, 'balance unchanged'); 

done_testing();

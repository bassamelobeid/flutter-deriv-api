use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit withdraw request decode_json);
use BOM::User::Client;

my $loginid = 'CR0012';

my $cli = BOM::User::Client->new({loginid => $loginid});
$cli->place_of_birth('id');
$cli->save;

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
$r = withdraw(
    loginid  => $loginid,
    trace_id => $trace_id,
    amount   => 1
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
like($r->content, qr[<opt>\s*<data></data>\s*</opt>], 'Correct content');
my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance - 1.00, 'Correct final balance');
ok($balance_now >= 1);
sleep 1;    # to make sure the trace_id is different

## try failed withdrawal_reversal
$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => 1,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 0,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => time(),
    });
is $r->code, 400, 'reject withdrawal reversal using bad trace_id';
like $r->decoded_content, qr/no corresponding original withdrawal could be found/, 'reject withdrawal reversal using bad trace_id nicely';

$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => 0.5,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 0,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => $trace_id,
    });
is $r->code, 400, 'reject withdrawal reversal using wrong amount';
like $r->decoded_content, qr/this does not match the original DoughFlow withdrawal request amount/,
    'reject withdrawal reversal using wrong amount nicely';

$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => $balance_now + 1,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 0,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => $trace_id,
    });
is $r->code, 400, 'reject withdrawal reversal using too-big amount';
like $r->decoded_content, qr/match the original/, '.. because does not match original?';

$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => 1,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 1,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => $trace_id,
    });
is $r->code, 400, 'cannot reverse withdrawal with fee';
like $r->decoded_content, qr/Bonuses and fees are not allowed for withdrawal reversals/, '.. no bonuses or fees allowed here';

# success one
$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => 1,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 0,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => $trace_id,
    });
is $r->code, 201;
$balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance + 0, 'Correct final balance');

## more fail
$r = request(
    'POST',
    '/transaction/payment/doughflow/withdrawal_reversal',
    {
        amount            => 1,
        client_loginid    => $loginid,
        created_by        => 'derek',
        currency_code     => 'USD',
        fee               => 0,
        ip_address        => '127.0.0.1',
        payment_processor => 'WebMonkey',
        trace_id          => $trace_id,
    });
is $r->code,              400;
like $r->decoded_content, qr/multiple corresponding original withdrawals were found/;

done_testing();

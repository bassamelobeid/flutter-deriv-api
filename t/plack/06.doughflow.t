use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit request decode_json);

my $loginid = 'CR0011';

my $starting_balance = balance($loginid);

my $trace_id = time();
my $r        = deposit(
    loginid  => $loginid,
    trace_id => $trace_id
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
like($r->content, qr[<opt>\s*<data></data>\s*</opt>], 'Correct content');
my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance + 1.00, 'Correct final balance');

## test duplicated transactions
$r = deposit(
    loginid  => $loginid,
    trace_id => $trace_id
);
is $r->code,              400;
like $r->decoded_content, qr/Detected duplicate transaction/i;
$balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance + 1.00, 'Correct final balance');

done_testing();

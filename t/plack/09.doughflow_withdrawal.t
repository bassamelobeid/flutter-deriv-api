use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit withdraw request decode_json);
use BOM::User::Client;

my $loginid = 'CR0011';

my $cli = BOM::User::Client->new({loginid => $loginid});
$cli->place_of_birth('id');
$cli->save;

my $r = deposit(
    loginid => $loginid,
    amount  => 2
);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');

sleep 1;    # so the payment_time DESC for get_last_payment_of_account will be correct

my $starting_balance = balance($loginid);
$r = withdraw(loginid => $loginid);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
like($r->content, qr[<opt>\s*<data></data>\s*</opt>], 'Correct content');
my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance - 1.00, 'Correct final balance');

my $location = $r->header('Location');
ok($location);

## test record_GET also
$location =~ s{^(.*?)/transaction}{/transaction};
$r = request('GET', $location);
my $data = decode_json($r->content);
is($data->{client_loginid}, $loginid);
is($data->{type},           'withdrawal');

# Failed tests
$r = withdraw(
    loginid  => $loginid,
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
$r = withdraw(
    loginid => $loginid,
    amount  => $balance_now + 1
);
is $r->code,              403;
like $r->decoded_content, qr/exceeds client balance/;
is(balance($loginid), $balance_now, 'Correct final balance (unchanged)');

done_testing();

use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit request decode_json);

my $loginid = 'CR0012';

my $starting_balance = balance($loginid);
my $r                = deposit(loginid => $loginid);
is($r->code,    201,       'correct status code');
is($r->message, 'Created', 'Correct message');
like($r->content, qr[<opt data="" />], 'Correct content');
my $balance_now = balance($loginid);
is(0 + $balance_now, $starting_balance + 1.00, 'Correct final balance');

my $location = $r->header('Location');
ok($location);

## test record_GET also
$location =~ s{^(.*?)/transaction}{/transaction};
$r = request('GET', $location);
my $data = decode_json($r->content);
is($data->{client_loginid}, $loginid);
is($data->{type}, 'deposit');

# Failed
$r = deposit(loginid => $loginid, trace_id => ' 123');
is($r->code,    400,           'Correct failure status code');
is($r->message, 'Bad Request', 'Correct message');
like($r->content, qr[(Attribute \(trace_id\) does not pass the type constraint|trace_id must be a positive integer)], 'Correct error message on response body');
is(balance($loginid), $balance_now, 'Correct final balance (unchanged)');

done_testing();

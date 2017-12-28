use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit);
use Encode;
use JSON::MaybeXS;

my $loginid = 'CR0011';

my $starting_balance = balance($loginid);
my $r                = deposit(
    loginid     => $loginid,
    is_validate => 1
);
is($r->code,                            200,                   'correct status code');
is(JSON::MaybeXS->new->decode(Encode::decode_utf8($r->content))->{allowed}, 1,                     'validate pass');
is(0 + balance($loginid),               $starting_balance + 0, 'balance is not changed.');

$r = deposit(
    loginid     => $loginid,
    amount      => 'Zzz',
    is_validate => 1
);
is($r->code, 400, 'Correct failure status code');
like($r->content, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message on response body');

done_testing();

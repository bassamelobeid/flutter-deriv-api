use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Test::MockModule;
use APIHelper qw(request decode_json);

my $loginid = 'CR0011';

my $r = request(
    'GET',
    '/account',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
    });
is $r->code, 200, "got $loginid USD account";
my $d = decode_json($r->content);
is $d->{client_loginid}, $loginid, "is $loginid";
is $d->{currency_code},  'USD',    "is USD";
ok $d->{balance} >= 0, "balance $d->{balance} >= 0";
ok $d->{limit} >= 0,   "limit $d->{limit} >=0";

$r = request(
    'GET',
    '/account',
    {
        client_loginid => $loginid,
        currency_code  => 'EUR',
    });
is $r->code, 400, "cannot GET a different currency to the one you have";

$r = request(
    'GET',
    '/account',
    {
        client_loginid => 'CR0999000',
        currency_code  => 'USD',
    });
is $r->code, 401, 'Authorization required for unexpected loginid';

$r = request(
    'GET',
    '/account',
    {
        client_loginid => $loginid,
    });
is $r->code, 400, 'missing currency_code';

$r = request(
    'GET',
    '/account',
    {
        client_loginid => $loginid,
        currency_code  => 'ZZZ',
    });
is $r->code, 400, 'wrong currency_code';

my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->redefine(balance_for_doughflow => 99);

$r = request(
    'GET',
    '/account',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
    });

is decode_json($r->content)->{balance}, '99.00', '$client->balance_for_doughflow is used for balance';

done_testing();

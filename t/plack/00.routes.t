use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(request);

my $loginid = 'CR0011';

## make sure all routues are there
my $r = request('GET', '/ping');
is $r->code, 200;

my @GETs = (
    '/account', '/client', '/client/address_diff', '/session', '/session/validate',
    '/transaction/payment/doughflow/record',
    '/transaction/payment/doughflow/record/',
    '/transaction/payment/doughflow/deposit_validate',
    '/transaction/payment/doughflow/withdrawal_validate'
);
my @POSTs = (
    '/client/address_diff',                      '/transaction/payment/doughflow/deposit',
    '/transaction/payment/doughflow/withdrawal', '/transaction/payment/doughflow/withdrawal_reversal'
);

foreach my $u (@GETs) {
    $r = request('GET', "$u?client_loginid=$loginid&currency_code=USD");
    ok($r->code != 404 and $r->code != 405);
}
foreach my $u (@POSTs) {
    $r = request('POST', "$u?client_loginid=$loginid&currency_code=USD");
    ok($r->code != 404 and $r->code != 405);
}

# failed one
@GETs = ('/transaction/payment/doughflow/deposit', '/transaction/payment/doughflow/withdrawal', '/transaction/payment/doughflow/withdrawal_reversal');
foreach my $u (@GETs) {
    $r = request('GET', "$u?client_loginid=$loginid&currency_code=USD");
    ok($r->code == 405|| $r->code == 401, "FAILED on $u: " . $r->code);    # not allowed
}
@POSTs = (
    '/client',                                '/session',
    '/session/validate',                      '/transaction/payment/doughflow/record',
    '/transaction/payment/doughflow/record/', '/transaction/payment/doughflow/deposit_validate',
    '/transaction/payment/doughflow/withdrawal_validate'
);
foreach my $u (@POSTs) {
    $r = request('POST', "$u?client_loginid=$loginid&currency_code=USD");
    ok($r->code == 405 || $r->code == 401, "FAILED on $u: " . $r->code);    # not allowed
}

done_testing();

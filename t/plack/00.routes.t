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
    '/account', '/client', '/session', '/session/validate',
    '/transaction/payment/doughflow/record',
    '/transaction/payment/doughflow/record/',
    '/transaction/payment/doughflow/deposit_validate',
    '/transaction/payment/doughflow/withdrawal_validate'
);
my @POSTs = (
    '/transaction/payment/doughflow/deposit',             '/transaction/payment/doughflow/withdrawal',
    '/transaction/payment/doughflow/withdrawal_reversal', '/transaction/payment/doughflow/create_payout',
    '/transaction/payment/doughflow/update_payout',       '/transaction/payment/doughflow/record_failed_deposit'
);

foreach my $u (@GETs) {
    $r = request('GET', "$u?client_loginid=$loginid&currency_code=USD");
    ok(($r->code != 404 and $r->code != 405 and $r->code != 500), "OK GET for $u") or diag 'response code was ' . $r->code;
}
foreach my $u (@POSTs) {
    $r = request('POST', "$u?client_loginid=$loginid&currency_code=USD");
    ok(($r->code != 404 and $r->code != 405 and $r->code != 500), "OK POST for $u") or note 'responst code was ' . $r->code;
}

# failed one
@GETs = (
    '/transaction/payment/doughflow/deposit',             '/transaction/payment/doughflow/withdrawal',
    '/transaction/payment/doughflow/withdrawal_reversal', '/transaction/payment/doughflow/create_payout',
    '/transaction/payment/doughflow/update_payout',       '/transaction/payment/doughflow/record_failed_deposit'
);
foreach my $u (@GETs) {
    $r = request('GET', "$u?client_loginid=$loginid&currency_code=USD");
    ok(($r->code == 405 and $r->code != 500), "FAILED on $u") or diag 'response code was ' . $r->code;    # not allowed
}
@POSTs = (
    '/client',                                '/session',
    '/session/validate',                      '/transaction/payment/doughflow/record',
    '/transaction/payment/doughflow/record/', '/transaction/payment/doughflow/deposit_validate',
    '/transaction/payment/doughflow/withdrawal_validate'
);
foreach my $u (@POSTs) {
    $r = request('POST', "$u?client_loginid=$loginid&currency_code=USD");
    ok(($r->code == 405 and $r->code != 500), "FAILED on $u") or diag 'response code was ' . $r->code;    # not allowed
}

done_testing();

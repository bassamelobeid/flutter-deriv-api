
use strict;
use warnings;

use Test::More;

use BOM::Config;
use LandingCompany::Registry;

subtest 'Get Payment Limits for all Real Landing Companies' => sub {
    my $payment_limits       = BOM::Config::payment_limits;
    my %short_code_by_broker = map { LandingCompany::Registry->by_broker($_)->short, $_ } LandingCompany::Registry::all_real_broker_codes;
    my @real_short_codes     = keys %short_code_by_broker;

    for my $short_code (@real_short_codes) {
        ok $payment_limits->{withdrawal_limits}->{$short_code}, 'There is withdrawal_limits for ' . $short_code;
    }

};

done_testing();

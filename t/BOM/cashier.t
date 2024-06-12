use strict;
use warnings;

use Test::More;

use BOM::Config;

subtest 'Cashier Sportsbooks name convention' => sub {
    my $cashier_config = BOM::Config::cashier_config();
    my $sportsbooks    = $cashier_config->{doughflow}{sportsbooks};
    for my $lc (keys %$sportsbooks) {
        like($sportsbooks->{$lc}, qr/^Deriv\b/, "$lc sportsbooks name starts with 'Deriv'");
    }
};

done_testing();

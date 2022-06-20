use strict;
use warnings;

use Test::More;

use BOM::Config;

subtest 'Cashier Sportsbooks name convention' => sub {
    my $cashier_config = BOM::Config::cashier_config();
    my $mapping        = $cashier_config->{doughflow}->{sportsbooks_mapping};
    for my $short_code (keys $mapping->%*) {
        subtest "$short_code honors the name convention" => sub {
            like($mapping->{$short_code}, qr/^Deriv\b/, "$short_code have a sportsbooks name starting with 'Deriv'");
        };
    }
};

done_testing();

#!/etc/rmg/bin/perl
use strict;
use warnings;

use Test::More tests => 1;
use Test::Exception;
use BOM::Platform::RiskProfile;


subtest 'get_current_profile_definitions' => sub {
    my $expected = {
        'commodities' => [{
                'turnover_limit' => 50000,
                'payout_limit'   => 5000,
                'name'           => 'Commodities',
                'profile_name'   => 'high_risk'
            }
        ],
        'volidx' => [{
                'turnover_limit' => 500000,
                'payout_limit'   => 50000,
                'name'           => 'Volatility Indices',
                'profile_name'   => 'low_risk'
            }
        ],
        'forex' => [{
                'turnover_limit' => 50000,
                'payout_limit'   => 5000,
                'name'           => 'Smart FX',
                'profile_name'   => 'high_risk',
            },
            {
                'turnover_limit' => 50000,
                'payout_limit'   => 5000,
                'name'           => 'Minor Pairs',
                'profile_name'   => 'high_risk',
            },
            {
                'turnover_limit' => 100000,
                'payout_limit'   => 20000,
                'name'           => 'Major Pairs',
                'profile_name'   => 'medium_risk',
            },
        ],
        'stocks' => [{
                'turnover_limit' => 10000,
                'payout_limit'   => 1000,
                'name'           => 'OTC Stocks',
                'profile_name'   => 'extreme_risk'
            }
        ],
        'indices' => [{
                'turnover_limit' => 100000,
                'payout_limit'   => 20000,
                'name'           => 'Indices',
                'profile_name'   => 'medium_risk'
            }]};
    my $general = BOM::Platform::RiskProfile::get_current_profile_definitions;
    is_deeply($general, $expected);
};

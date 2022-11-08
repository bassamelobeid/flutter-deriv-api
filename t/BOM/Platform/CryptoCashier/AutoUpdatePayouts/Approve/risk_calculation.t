use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Future::AsyncAwait;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

my $auto_approval_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
    broker_code           => 'cr',
    acceptable_percentage => 20
);

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve::risk_calculation' => sub {
    my @settings = (
        # [deposit, withdraw, acceptable_percentage, is_acceptable, risk_percentage]
        [10, 0,  20, 0, 100],
        [10, 1,  20, 0, 90],
        [10, 2,  20, 0, 80],
        [10, 3,  20, 0, 70],
        [10, 4,  20, 0, 60],
        [10, 5,  20, 0, 50],
        [10, 6,  20, 0, 40],
        [10, 7,  20, 0, 30],
        [10, 8,  20, 0, 20],
        [10, 9,  20, 1, 10],
        [10, 10, 20, 1, 0]);
    is_deeply(
        $auto_approval_obj->risk_calculation(
            deposit               => $settings[0]->[0],
            withdraw              => $settings[0]->[1],
            acceptable_percentage => $auto_approval_obj->{acceptable_percentage}
        ),
        {
            is_acceptable   => $settings[0]->[3],
            risk_percentage => $settings[0]->[4]
        },
        "withdraw of $settings[0]->[1] on a total deposit of $settings[0]->[0] with $auto_approval_obj->{acceptable_percentage}% of acceptable percentage, is acceptable? "
            . ($settings[0]->[3] ? 'YES' : 'NO'));

    for my $setting (@settings) {
        is_deeply(
            $auto_approval_obj->risk_calculation(
                deposit               => $setting->[0],
                withdraw              => $setting->[1],
                acceptable_percentage => $setting->[2]
            ),
            {
                is_acceptable   => $setting->[3],
                risk_percentage => $setting->[4]
            },
            "withdraw of $setting->[1] on a total deposit of $setting->[0] with $setting->[2]% of acceptable percentage, is acceptable? "
                . ($setting->[3] ? 'YES' : 'NO'));
    }
};

done_testing;

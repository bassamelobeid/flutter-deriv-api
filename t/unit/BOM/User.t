use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use Test::Deep;

# We're gonna try to use a pure object, no DB involved.
# Mock all the stuff you need.

my $user_mock = Test::MockModule->new('BOM::User');
$user_mock->redefine(new => sub { return bless({}, 'BOM::User') });

my @loginid_data;
my $dbic_mock = Test::MockObject->new();
$dbic_mock->mock(run => sub { \@loginid_data });
$user_mock->redefine(dbic => $dbic_mock);

my $user = BOM::User->new;

subtest 'get_trading_platform_loginids' => sub {
    my @loginids;
    $user_mock->mock(
        'loginids',
        sub {
            return @loginids;
        });

    my $tests = [{
            loginids  => [qw/DXR10011 DXD10001 DXD10004 MTD14124 MTR1412412 MTR1412112 CR124124 CR124125/],
            platforms => {
                dxtrader => {
                    demo  => [qw/DXD10004 DXD10001/],
                    real  => [qw/DXR10011/],
                    all   => [qw/DXD10004 DXD10001 DXR10011/],
                    whole => [],
                    whale => [],
                },
                mt5 => {
                    demo => [qw/MTD14124/],
                    real => [qw/MTR1412412 MTR1412112/],
                    all  => [qw/MTD14124 MTR1412412 MTR1412112/],
                },
                wrong => {
                    demo => [],
                    real => [],
                    all  => [],
                },
            }
        },
        {
            loginids  => [qw/DXR10011 MTR1412412 MTR1412112 CR124124 CR124125/],
            platforms => {
                dxtrader => {
                    demo => [],
                    real => [qw/DXR10011/],
                    all  => [qw/DXR10011/],
                },
                mt5 => {
                    demo => [],
                    real => [qw/MTR1412412 MTR1412112/],
                    all  => [qw/MTR1412412 MTR1412112/],
                },
                stuff => {
                    demo => [],
                    real => [],
                    all  => [],
                },
            }
        },
        {
            loginids  => [],
            platforms => {
                dxtrader => {
                    demo => [],
                    real => [],
                    all  => [],
                },
                mt5 => {
                    demo => [],
                    real => [],
                    all  => [],
                },
                nothing => {
                    demo => [],
                    real => [],
                    all  => [],
                },
            }
        },
    ];

    for my $test ($tests->@*) {
        @loginids = $test->{loginids}->@*;

        for my $platform (keys $test->{platforms}->%*) {
            for my $account_type (keys $test->{platforms}->{$platform}->%*) {
                cmp_deeply(
                    [$user->get_trading_platform_loginids($platform, $account_type)],
                    bag($test->{platforms}->{$platform}->{$account_type}->@*),
                    "Expected loginids returned: $platform x $account_type"
                );
            }
        }
    }

    $user_mock->unmock('loginids');
};

subtest 'get_mt5_loginids' => sub {
    my @loginids;
    $user_mock->mock(
        loginids          => sub { return @loginids },
        is_active_loginid => 1,
    );

    my $tests = [{
            loginids => [qw/DXR10011 DXD10001 DXD10004 MTD14124 MTR1412412 MTR1412112 CR124124 CR124125/],
            types    => {
                demo => [qw/MTD14124/],
                real => [qw/MTR1412412 MTR1412112/],
                all  => [qw/MTD14124 MTR1412412 MTR1412112/],
            }}];

    for my $test ($tests->@*) {
        @loginids = $test->{loginids}->@*;

        for my $account_type (keys $test->{types}->%*) {
            cmp_deeply(
                [$user->get_mt5_loginids(type_of_account => $account_type)],
                bag($test->{types}->{$account_type}->@*),
                "Expected loginids returned: mt5 x $account_type"
            );
        }
    }

    $user_mock->unmock('loginids');
    $user_mock->unmock('is_active_loginid');
};

subtest 'filter_active_ids with status' => sub {
    my $loginid_details = {};
    my $expected;

    $user_mock->mock(
        'loginid_details',
        sub {
            return $loginid_details;
        });

    my $tests = [{
            loginids => {
                MTR1000 => {
                    status   => 'poa_outdated',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1000/],
        },
        {
            loginids => {
                MTR1000 => {
                    status   => 'xxx',
                    platform => 'mt5'
                }
            },
            expected => [qw//],
        },
        {
            loginids => {
                MTR1001 => {
                    status   => 'poa_pending',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1001/],
        },
        {
            loginids => {
                MTR1002 => {
                    status   => 'poa_rejected',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1002/],
        },
        {
            loginids => {
                MTR1003 => {
                    status   => 'poa_failed',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1003/],
        },
        {
            loginids => {
                MTR1004 => {
                    status   => 'proof_failed',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1004/],
        },
        {
            loginids => {
                MTR1005 => {
                    status   => 'verification_pending',
                    platform => 'mt5'
                }
            },
            expected => [qw/MTR1005/],
        },
        {
            loginids => {
                MTR1006 => {
                    status   => undef,
                    platform => 'mt5',
                }
            },
            expected => [qw/MTR1006/],
        },
        {
            loginids => {MTR1007 => {platform => 'mt5'}},
            expected => [qw/MTR1007/],
        },
        {
            loginids => {
                MTD1000 => {
                    platform => 'mt5',
                },
                MTD1001 => {
                    status   => undef,
                    platform => 'mt5',
                },
                MTD1002 => {
                    status   => 'dunno',
                    platform => 'mt5'
                },
                MTD1003 => {
                    status   => 'poa_outdated',
                    platform => 'mt5'
                },
            },
            expected => [qw/MTD1000 MTD1001 MTD1003/],
        },
    ];

    for my $test ($tests->@*) {
        $loginid_details         = $test->{loginids};
        $user->{loginid_details} = $loginid_details;
        $expected                = $test->{expected};

        cmp_bag $user->filter_active_ids([keys $loginid_details->%*]), $expected, "Expected test MT5 loginid list";
    }
};

done_testing();

use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

# We're gonna try to use a pure object, no DB involved.
# Mock all the stuff you need.

my $user_mock = Test::MockModule->new('BOM::User');
$user_mock->mock(
    'new',
    sub {
        return bless({}, 'BOM::User');
    });

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
        'loginids',
        sub {
            return @loginids;
        });

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
                [$user->get_mt5_loginids($account_type)],
                bag($test->{types}->{$account_type}->@*),
                "Expected loginids returned: mt5 x $account_type"
            );
        }
    }

    $user_mock->unmock('loginids');
};

subtest 'broker_code_from_loginid' => sub {
    is($user->broker_code_from_loginid('CR000002'),   'CR',   'broker short code CR');
    is($user->broker_code_from_loginid('VRTC010000'), 'VRTC', 'broker short code VRTC');
};

done_testing();

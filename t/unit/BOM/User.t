use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::User;

# We're gonna try to use a pure object, no DB involved.
# Mock all the stuff you need.

my $user_mock = Test::MockModule->new('BOM::User');
$user_mock->redefine(new => sub { return bless({}, 'BOM::User') });

my $db_mock = Test::MockModule->new('DBIx::Connector');
my @loginid_data;
$db_mock->mock(run => sub { \@loginid_data });

my $user = BOM::User->new;

subtest 'get_trading_platform_loginids' => sub {

    my $tests = [{
            loginids  => [qw/DXR10011 DXD10001 DXD10004 MTD14124 MTR1412412 MTR1412112 CR124124 CR124125/],
            platforms => {
                dxtrade => {
                    demo => [qw/DXD10004 DXD10001/],
                    real => [qw/DXR10011/],
                    all  => [qw/DXD10004 DXD10001 DXR10011/],
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
                dxtrade => {
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
        delete $user->{loginid_details};
        @loginid_data = map { {loginid => $_} } $test->{loginids}->@*;

        for my $platform (keys $test->{platforms}->%*) {
            for my $account_type (keys $test->{platforms}->{$platform}->%*) {
                cmp_deeply(
                    [$user->get_trading_platform_loginids(platform => $platform, type_of_account => $account_type)],
                    bag($test->{platforms}->{$platform}->{$account_type}->@*),
                    "Expected loginids returned: $platform -> $account_type"
                );
            }
        }
    }
};

subtest 'get_mt5_loginids' => sub {

    my $tests = [{
            loginids => [qw/DXR10011 DXD10001 DXD10004 MTD14124 MTR1412412 MTR1412112 CR124124 CR124125/],
            types    => {
                demo => [qw/MTD14124/],
                real => [qw/MTR1412412 MTR1412112/],
                all  => [qw/MTD14124 MTR1412412 MTR1412112/],
            }}];

    for my $test ($tests->@*) {
        delete $user->{loginid_details};
        @loginid_data = map { {loginid => $_} } $test->{loginids}->@*;

        for my $account_type (keys $test->{types}->%*) {
            cmp_deeply(
                [$user->get_mt5_loginids(type_of_account => $account_type)],
                bag($test->{types}->{$account_type}->@*),
                "Expected loginids returned: mt5 -> $account_type"
            );
        }
    }
};

subtest 'filter_active_ids with status' => sub {

    my $tests = [{
            loginids => [{
                    loginid => 'MTR1000',
                    status  => 'poa_outdated'
                },
            ],
            expected => [qw/MTR1000/],
        },
        {
            loginids => [{
                    loginid => 'MTR1000',
                    status  => 'xxx'
                },
            ],
            expected => [],
        },
        {
            loginids => [{
                    loginid => 'MTR1001',
                    status  => 'poa_pending'
                },
            ],
            expected => [qw/MTR1001/],
        },
        {
            loginids => [{
                    loginid => 'MTR1002',
                    status  => 'poa_rejected'
                },
            ],
            expected => [qw/MTR1002/],
        },
        {
            loginids => [{
                    loginid => 'MTR1003',
                    status  => 'poa_failed'
                },
            ],
            expected => [qw/MTR1003/],
        },
        {
            loginids => [{
                    loginid => 'MTR1004',
                    status  => 'proof_failed'
                },
            ],
            expected => [qw/MTR1004/],
        },
        {
            loginids => [{
                    loginid => 'MTR1005',
                    status  => 'verification_pending'
                },
            ],
            expected => [qw/MTR1005/],
        },
        {
            loginids => [
                {loginid => 'MTD1000'},
                {
                    loginid => 'MTD1001',
                    status  => undef
                },
                {
                    loginid => 'MTD1002',
                    status  => 'dunno'
                },
                {
                    loginid => 'MTD1003',
                    status  => 'poa_outdated'
                },
            ],
            expected => [qw/MTD1000 MTD1001 MTD1003/],
        },
    ];

    for my $test ($tests->@*) {

        delete $user->{loginid_details};
        @loginid_data = $test->{loginids}->@*;
        my @logins = map { $_->{loginid} } $test->{loginids}->@*;

        cmp_bag $user->filter_active_ids(\@logins), $test->{expected}, "Expected test MT5 loginid list";
    }
};

done_testing();

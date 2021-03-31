use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Scalar::Util qw(refaddr);
use BOM::Config::Runtime;

use BOM::TradingPlatform;

subtest 'Instantiate trading platform' => sub {

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    my $tests = [{
            platform => 'mt5',
            lives    => 1,
            class    => 'BOM::TradingPlatform::MT5',
        },
        {
            platform => 'dxtrade',
            lives    => 1,
            class    => 'BOM::TradingPlatform::DXTrader',
        },
        {
            platform => 'dummy',
            lives    => 0,
        }];

    for my $test ($tests->@*) {
        my ($platform, $lives, $class) = @{$test}{qw/platform lives class/};
        my $trading_platform;

        my $error = exception {
            $trading_platform = BOM::TradingPlatform->new(platform => $platform);
        };

        ok !$error, "$platform should make it" if $lives;
        is ref($trading_platform), $class, "Correct class for $platform" if $class;
        ok $trading_platform->isa('BOM::TradingPlatform'), "$platform is a valid BOM::TradingPlatform implementation" if $class;

        ok $error, "$platform should die" unless $lives;
        ok $error =~ qr/\bUnknown trading platform: $platform\b/, "$platform death cause is correct" unless $lives;
    }
};

subtest 'Implementation completeness' => sub {
    my $abstract_methods = [BOM::TradingPlatform::INTERFACE];

    my $tests = {
        mt5 => {
            new_account        => 0,
            change_password    => 0,
            deposit            => 0,
            withdraw           => 0,
            get_account_info   => 1,
            get_accounts       => 0,
            get_open_positions => 0,
        },
        dxtrade => {
            new_account        => 1,
            change_password    => 1,
            deposit            => 1,
            withdraw           => 1,
            get_account_info   => 1,
            get_accounts       => 1,
            get_open_positions => 1,
        },
    };

    for my $platform (keys $tests->%*) {
        my $trading_platform = BOM::TradingPlatform->new(platform => $platform);

        for my $method ($abstract_methods->@*) {
            ok defined $tests->{$platform}->{$method}, "$platform has a test for $method";

            my $implemented = $tests->{$platform}->{$method};

            if ($implemented) {
                isnt $trading_platform->can($method), BOM::TradingPlatform->can($method), "$platform has a $method implementation";
            } else {
                is $trading_platform->can($method), BOM::TradingPlatform->can($method), "$platform does not have a $method implementation";

                my $error = exception {
                    $trading_platform->$method;
                };

                my $expected = sprintf('%s not yet implemented by %s', $method, ref($trading_platform));
                ok $error =~ qr/\b$expected\b/, "$platform reports an unimplemented $method subroutine";
            }
        }
    }
};

subtest 'Instantiate the platform without factory' => sub {
    my $classes = [
        qw/
            BOM::TradingPlatform::MT5
            BOM::TradingPlatform::DXTrader
            /
    ];

    for my $class ($classes->@*) {
        my $platform = $class->new();
        isa_ok($platform, $class);
    }

    isa_ok(BOM::TradingPlatform->new_base(), 'BOM::TradingPlatform');
};

subtest 'DXtrade suspend' => sub {
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    cmp_deeply(exception { BOM::TradingPlatform->new(platform => 'dxtrade') }, {error_code => 'DXSuspended'}, 'use factory');
    cmp_deeply(exception { BOM::TradingPlatform::DXTrader->new },              {error_code => 'DXSuspended'}, 'use direct');
    is exception { BOM::TradingPlatform->new(platform => 'mt5') }, undef, 'mt5 unaffected';
};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Test::RPC::QueueClient;
use BOM::RPC::v3::Trading;
use BOM::Config::Runtime;
use BOM::Config::MT5;

my $c = BOM::Test::RPC::QueueClient->new();

sub set_mt5_to_active {
    my ($group_type) = @_;

    my $mt5_servers = BOM::Config::MT5->new(group_type => $group_type)->servers;
    my $server_name;

    foreach my $number (keys $mt5_servers->@*) {
        ($server_name) = %{$mt5_servers->[$number]};
        $server_name =~ m/p(\d+)_ts(\d+)/;
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->$group_type->$server_name->all(0);
    }
}

sub set_mt5_to_maintenance {
    my ($group_type) = @_;

    my $mt5_servers = BOM::Config::MT5->new(group_type => $group_type)->servers;
    my $server_name;

    foreach my $number (keys $mt5_servers->@*) {
        ($server_name) = %{$mt5_servers->[$number]};
        $server_name =~ m/p(\d+)_ts(\d+)/;
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->$group_type->$server_name->all(1);
    }
}

sub set_all_platforms_to_active {

    my $dxtrade_servers_config = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;
    $dxtrade_servers_config->all(0);
    $dxtrade_servers_config->demo(0);
    $dxtrade_servers_config->real(0);

    my $ctrader_servers_config = BOM::Config::Runtime->instance->app_config->system->ctrader->suspend;
    $ctrader_servers_config->all(0);
    $ctrader_servers_config->demo(0);
    $ctrader_servers_config->real(0);

    set_mt5_to_active('demo');
    set_mt5_to_active('real');
}

my $expected_result = [{
        platform => 'ctrader',
        status   => 'active',
    },
    {
        platform => 'dxtrade',
        status   => 'active',
    },
    {
        platform => 'mt5',
        status   => 'active',
    },
];

set_all_platforms_to_active();

my $method = 'trading_platform_status';

subtest 'is_platform_suspended_derivX' => sub {

    my $dxtrade_servers_config = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;
    my $result                 = $c->call_ok('trading_platform_status')->result;
    cmp_deeply($result, $expected_result, 'Correct trading platform statuses returned on trading_platform_status call');

    $dxtrade_servers_config->all(1);
    $expected_result->[1]->{status} = 'maintenance';

    $result = $c->call_ok('trading_platform_status')->result;
    cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');

    $dxtrade_servers_config->all(0);

    subtest 'only demo suspension shouldnt result in maintainence flag' => sub {
        #only demos are down:
        $dxtrade_servers_config->demo(1);
        $dxtrade_servers_config->real(0);
        $result = $c->call_ok('trading_platform_status')->result;
        $expected_result->[1]->{status} = 'active';
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $dxtrade_servers_config->demo(0);
    };

    subtest 'only real suspension shouldnt result in maintainence flag' => sub {

        #only reals are down
        $dxtrade_servers_config->real(1);
        $result = $c->call_ok('trading_platform_status')->result;
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $dxtrade_servers_config->real(0);
    };

    subtest 'both real and demo are down and flag should be maintainence' => sub {

        #both reals and demos are down
        $dxtrade_servers_config->real(1);
        $dxtrade_servers_config->demo(1);
        $result = $c->call_ok('trading_platform_status')->result;
        $expected_result->[1]->{status} = 'maintenance';
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $dxtrade_servers_config->real(0);
        $dxtrade_servers_config->demo(0);
        $expected_result->[1]->{status} = 'active';
    };
};

subtest 'is_platform_suspended_mt5' => sub {

    my $trading_platform = Deriv::TradingPlatform::create(
        platform => 'mt5',
        client   => 'client'
    );

    my $mt5_api_suspend_config = BOM::Config::Runtime->instance->app_config->system->mt5->suspend;

    $mt5_api_suspend_config->all(1);
    my $result = $c->call_ok('trading_platform_status')->result;
    #$expected_result->[1]->{status} = 'maintenance';
    $expected_result->[2]->{status} = 'maintenance';
    cmp_deeply($result, $expected_result, 'mt5_suspend_all_returns_correct_status');
    $mt5_api_suspend_config->all(0);

    subtest 'only demo suspension shouldnt result in maintainence flag' => sub {
        #only demos are down:
        set_mt5_to_maintenance('demo');
        $result = $c->call_ok('trading_platform_status')->result;
        #$expected_result->[1]->{status} = 'active';
        $expected_result->[2]->{status} = 'active';
        cmp_deeply($result, $expected_result, 'mt5_suspend_all_returns_correct_status');
        set_mt5_to_active('demo');
    };

    subtest 'only real suspension shouldnt result in maintainence flag' => sub {

        #only reals are down
        set_mt5_to_maintenance('real');
        $result = $c->call_ok('trading_platform_status')->result;
        cmp_deeply($result, $expected_result, 'mt5_suspend_all_returns_correct_status');
        set_mt5_to_active('real');
        set_mt5_to_active('demo');

    };

    subtest 'both real and demo are down and flag should be maintainence' => sub {

        #both reals and demos are down
        set_mt5_to_maintenance('real');
        set_mt5_to_maintenance('demo');
        $result = $c->call_ok('trading_platform_status')->result;
        #$expected_result->[1]->{status} = 'maintenance';
        $expected_result->[2]->{status} = 'maintenance';
        cmp_deeply($result, $expected_result, 'mt5_suspend_all_returns_correct_status');
        set_mt5_to_active('real');
        set_mt5_to_active('demo');
        #$expected_result->[1]->{status} = 'active';
        $expected_result->[2]->{status} = 'active';
    }
};

subtest 'is_platform_suspended_derivX' => sub {

    my $ctrader_servers_config = BOM::Config::Runtime->instance->app_config->system->ctrader->suspend;

    $ctrader_servers_config->all(1);
    $expected_result->[0]->{status} = 'maintenance';

    my $result = $c->call_ok('trading_platform_status')->result;
    cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');

    $ctrader_servers_config->all(0);

    subtest 'only demo suspension shouldnt result in maintainence flag' => sub {
        #only demos are down:
        $ctrader_servers_config->demo(1);
        $ctrader_servers_config->real(0);
        $result = $c->call_ok('trading_platform_status')->result;
        $expected_result->[0]->{status} = 'active';
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $ctrader_servers_config->demo(0);
    };

    subtest 'only real suspension shouldnt result in maintainence flag' => sub {

        #only reals are down
        $ctrader_servers_config->real(1);
        $result = $c->call_ok('trading_platform_status')->result;
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $ctrader_servers_config->real(0);
    };

    subtest 'both real and demo are down and flag should be maintainence' => sub {

        #both reals and demos are down
        $ctrader_servers_config->real(1);
        $ctrader_servers_config->demo(1);
        $result = $c->call_ok('trading_platform_status')->result;
        $expected_result->[0]->{status} = 'maintenance';
        cmp_deeply($result, $expected_result, 'dxtrade_suspend_all_returns_correct_status');
        $ctrader_servers_config->real(0);
        $ctrader_servers_config->demo(0);
        $expected_result->[0]->{status} = 'active';
    };
};

subtest 'Correct trading platform statuses returned on trading_platform_status call' => sub {

    my $expected_result = [{
            platform => 'ctrader',
            status   => 'active',
        },
        {
            platform => 'dxtrade',
            status   => 'active',
        },
        {
            platform => 'mt5',
            status   => 'active',
        },
    ];

    my $result = $c->call_ok('trading_platform_status')->result;
    cmp_deeply($result, $expected_result, 'Correct trading platform statuses returned on trading_platform_status call');

};

done_testing();

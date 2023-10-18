use Test::Most;
use Test::MockModule;
use Test::MockTime::HiRes                   qw(set_absolute_time);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

set_absolute_time('2022-09-21T10:00:00Z');
note "set time to: " . Date::Utility->new->date . " - " . Date::Utility->new->epoch;
initialize_realtime_ticks_db();

our %stats;
our %del_keys;

local $SIG{__WARN__} = sub {
    # capture the warn for test
    my $msg = shift;
};

my $subchannel  = "v1,AUD,10,stake,0,0.025,0.012,0.02,0.35,50000,,";
my $mock_daemon = Test::MockModule->new('BOM::Pricing::PriceDaemon');
$mock_daemon->mock('stats_inc', sub { my ($key, $tag) = @_; $stats{$key}++; });

my $redis_pricer = BOM::Config::Redis::redis_pricer(timeout => 0);
my $daemon       = BOM::Pricing::PriceDaemon->new(
    tags                 => ["tag:test"],
    record_price_metrics => 0,
);

subtest '_validate_params daemon' => sub {
    my $params = {
        'currency'         => 'AUD',
        'contract_type'    => 'CALL',
        'symbol'           => 'frxAUDJPY',
        'price_daemon_cmd' => '',
    };
    my $result = $daemon->_validate_params(undef, $params);
    ok !$result,                       'missing price_daemon_cmd';
    ok $stats{'pricer_daemon.no_cmd'}, 'pricer_daemon.no_cmd';

    $params->{price_daemon_cmd} = 'test';
    $result = $daemon->_validate_params(undef, $params);
    ok !$result,                                'invalid price_daemon_cmd';
    ok $stats{'pricer_daemon.unknown.invalid'}, 'pricer_daemon.unknown.invalid';

    $params->{price_daemon_cmd} = 'bid';
    $result = $daemon->_validate_params(undef, $params);
    ok !$result,                                       'lack of required_params';
    ok $stats{'pricer_daemon.required_params_missed'}, 'pricer_daemon.required_params_missed';

    $params->{price_daemon_cmd} = 'price';
    $result = $daemon->_validate_params(undef, $params);
    ok $result, 'params valide';

};

subtest 'process_job' => sub {
    my $params = {
        'basis'                  => 'payout',
        'currency'               => 'AUD',
        'duration'               => 3,
        'skips_price_validation' => 1,
        'contract_type'          => 'CALL',
        'landing_company'        => 'svg',
        'symbol'                 => 'frxAUDJPY',
        'price_daemon_cmd'       => 'price',
        'amount'                 => 100,
        'proposal'               => 1,
        'product_type'           => 'basic',
        'country_code'           => 'id',
        'duration_unit'          => 'm'
    };

    my $result = $daemon->process_job($redis_pricer, $params, $params);

    ok $result->{error}, 'process_job error';
    is $result->{'price_daemon_cmd'}, 'price', 'price_daemon_cmd price';

    $params = {
        'barrier'         => 'S0P',
        'is_sold'         => 0,
        'duration'        => '15m',
        'bet_type'        => 'RESETCALL',
        'underlying'      => 'R_50',
        'currency'        => 'USD',
        'date_start'      => 0,
        'amount_type'     => 'payout',
        'payout'          => '10',
        'short_code'      => 'DIGITMATCH_R_10_18.18_0_5T_7_0',
        'symbol'          => 'frxAUDJPY',
        'landing_company' => 'svg',
    };

    $params->{price_daemon_cmd} = 'bid';
    $result = $daemon->process_job($redis_pricer, $params, $params);

    my $expected = {
        'barrier'                    => '7',
        'barrier_count'              => 1,
        'bid_price'                  => '1.64',
        'contract_id'                => undef,
        'contract_type'              => 'DIGITMATCH',
        'currency'                   => 'USD',
        'current_spot'               => '963.305',
        'current_spot_display_value' => '963.305',
        'current_spot_time'          => ignore(),
        'date_expiry'                => ignore(),
        'date_settlement'            => ignore(),
        'date_start'                 => ignore(),
        'display_name'               => 'Volatility 10 Index',
        'expiry_time'                => ignore(),
        'is_expired'                 => 0,
        'is_forward_starting'        => 0,
        'is_intraday'                => 1,
        'is_path_dependent'          => 0,
        'is_settleable'              => 0,
        'is_sold'                    => 0,
        'is_valid_to_cancel'         => 0,
        'is_valid_to_sell'           => 0,
        'longcode'                   =>
            ["Win payout if the last digit of [_1] is [_4] after [plural,_3,%d tick,%d ticks].", ["Volatility 10 Index"], ["first tick"], [5], 7,],
        'payout'                => '18.18',
        'price_daemon_cmd'      => 'bid',
        'rpc_time'              => ignore(),
        'shortcode'             => ignore(),
        'status'                => 'open',
        'tick_count'            => '5',
        'tick_stream'           => [],
        'underlying'            => 'R_10',
        'validation_error'      => ignore(),
        'validation_error_code' => ignore()};
    cmp_deeply($result, $expected, 'process_job result matches');

};

subtest 'deserialize_contract_parameters' => sub {

    my $contract_params = {
        amount                => 10,
        amount_type           => "stake",
        app_markup_percentage => 0,
        base_commission       => "0.012",
        currency              => "AUD",
        deep_otm_threshold    => "0.025",
        min_commission_amount => "0.02",
        staking_limits        => {
            max => 50000,
            min => "0.35",
        },
    };

    is_deeply(
        $contract_params,
        BOM::Pricing::PriceDaemon::_deserialize_contract_parameters(undef, $subchannel),
        "proposal subchannel's are correctly deconstructed"
    );
};

subtest 'run' => sub {
    my @pricer_queue = (
        ['invalid_param', 'invalid_param'],
        [
            'current_queue_1',
            'PRICER_ARGS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]',
        ],
        [
            'current_queue_2',
            'PRICER_ARGS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]',
        ],
        [
            'current_queue_3',
            'PRICER_ARGS::["short_code","PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0","contract_id","123","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]',
        ]);

    my $mock_redis = Test::MockModule->new('RedisDB');
    $mock_redis->mock(
        'smembers',
        sub {
            return [$subchannel];
        });

    ok $daemon->isa('BOM::Pricing::PriceDaemon'), 'new PriceDaemon';

    $daemon->{is_running} = 1;
    ok $daemon->is_running, 'is running';

    $daemon->stop;
    ok !$daemon->is_running, 'daemon stop';

    $mock_redis->mock(
        'brpop',
        sub {
            die 'exit loop';
        });

    throws_ok {
        $daemon->run(
            queues     => ['pricer_jobs'],
            ip         => '127.0.0.1',
            pid        => 0,
            fork_index => 0
        )
    }
    qr/exit loop/, 'exit loop for error';

    $mock_redis->mock(
        'del',
        sub {
            my ($self, $keys) = @_;
            $del_keys{$keys} = 1;
        });

    $mock_redis->mock(
        'brpop',
        sub {
            return pop @pricer_queue;
        });

    lives_ok {
        $daemon->run(
            queues     => ['pricer_jobs'],
            ip         => '127.0.0.1',
            pid        => 0,
            fork_index => 0
        )
    }
    'daemon run';

    ok $del_keys{
        'PRICER_ARGS::["short_code","PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0","contract_id","123","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]'
    }, 'del invalid keys';
};

subtest 'country code' => sub {

    my $subchannel = "v1,AUD,200,stake,0,0.025,0.012,0.03,,,,100,EN";
    my $expected   = "EN";

    my $actual = BOM::Pricing::PriceDaemon::get_local_language($subchannel);

    is($actual, $expected, "correct language code");
};

done_testing;

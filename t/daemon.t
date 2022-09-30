use Test::Most;
use Test::MockModule;
use Test::MockObject;

use BOM::Pricing::PriceDaemon;
our %stats;
our %del_keys;
my $mock_daemon = Test::MockModule->new('BOM::Pricing::PriceDaemon');
$mock_daemon->mock('stats_inc', sub { my ($key, $tag) = @_; $stats{$key}++; });

my @pricer_queue = (
    ['invalid_param', 'invalid_param'],
    [
        'current_queue_1',
        'PRICER_ARGS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]',
    ],

    [
        'current_queue_2',
        'PRICER_ARGS::["amount",1000,"basis","payout","contract_id",123,"contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]',
    ],
    [
        'current_queue_3',

        'PRICER_ARGS::["short_code","PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0","contract_id","123","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]',

    ]);

my $mock_redis = Test::MockModule->new('RedisDB');

$mock_redis->mock(
    'brpop',
    sub {
        return pop @pricer_queue;
    });
$mock_redis->mock(
    'del',
    sub {
        my $keys = shift;
        $del_keys{$keys} = 1;
    });

my $redis_pricer = BOM::Config::Redis::redis_pricer(timeout => 0);
my $daemon       = BOM::Pricing::PriceDaemon->new(
    tags                 => ["tag:test"],
    record_price_metrics => 0,
    price_duplicate_spot => 0,
);

subtest 'run' => sub {

    $mock_redis->mock(
        'brpop',
        sub {
            return pop @pricer_queue;
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
    note explain \%del_keys;

    note $daemon->current_queue;

};
done_testing;

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

    my $result   = $daemon->process_job($redis_pricer, $params, $params);
    my $expected = {
        'error' => {
            'code'              => 'ContractCreationFailure',
            'message_to_client' => 'Cannot create contract'
        },
        'price_daemon_cmd' => 'price',
        'rpc_time'         => ignore()};

    cmp_deeply($result, $expected, 'command price with error');

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
        'error' => {
            'code'              => 'GetProposalFailure',
            'message_to_client' => 'Sorry, an error occurred while processing your request.'
        },
        'price_daemon_cmd' => 'bid',
        'rpc_time'         => ignore()};

    cmp_deeply($result, $expected, 'command bid with error');

};

done_testing;


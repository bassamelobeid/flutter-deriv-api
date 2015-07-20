use strict;
use warnings;
use Test::MockTime qw( set_fixed_time restore_time );
use Test::Most (tests => 37);
use Test::NoWarnings;
use Test::MockModule;

use Test::Exception;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Market::Data::Tick;
use BOM::Database::Helper::FinancialMarketBet;

use BOM::Platform::Client;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use Format::Util::Numbers qw(roundnear);

my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

initialize_realtime_ticks_db;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol                   => 'FSE',
        delay_amount             => 0,
        offered                  => 'yes',
        display_name             => 'FSE',
        trading_timezone         => 'UTC',
        tenfore_trading_timezone => 'NA',
        open_on_weekends         => 1,
        currency                 => 'NA',
        bloomberg_calendar_code  => 'NA',
        holidays                 => {},
        market_times             => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol                   => 'RANDOM',
        delay_amount             => 0,
        offered                  => 'yes',
        display_name             => 'Randoms',
        trading_timezone         => 'UTC',
        tenfore_trading_timezone => 'NA',
        open_on_weekends         => 1,
        currency                 => 'NA',
        bloomberg_calendar_code  => 'NA',
        holidays                 => {},
        market_times             => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol                   => 'FOREX',
        delay_amount             => 0,
        offered                  => 'yes',
        display_name             => 'Forex',
        trading_timezone         => 'UTC',
        tenfore_trading_timezone => 'NA',
        open_on_weekends         => 1,
        currency                 => 'NA',
        bloomberg_calendar_code  => 'NA',
        holidays                 => {},
        market_times             => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol                   => 'FSE-LSE',
        delay_amount             => 0,
        offered                  => 'yes',
        display_name             => 'FSE-LSE',
        trading_timezone         => 'UTC',
        tenfore_trading_timezone => 'NA',
        open_on_weekends         => 1,
        currency                 => 'NA',
        bloomberg_calendar_code  => 'NA',
        holidays                 => {},
        market_times             => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new
    }) for qw(EUR USD);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( USD EUR );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw/R_50 R_75/;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'correlation_matrix',
    {
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(GDAXI R_75 R_50);

my $bet_mapper;
lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0005',
        'currency_code'  => 'USD',
    });

}
'Expect to initialize the object';
cmp_ok($bet_mapper->get_turnover_of_client({'bet_type' => ['INTRAD', 'CALL']}), '==', 0, 'Check INTRA turnover of CR0005, GBP');

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0008',
        'currency_code'  => 'USD',
    });

}
'Expect to initialize the object';
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'         => ['FLASH', 'PUT'],
            'overall_turnover' => 1
        }
    ),
    '==', 15501,
    'Check FLASH, PUT turnover of CR0008, USD'
);
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'         => ['FLASH', 'TOUCH', 'PUT'],
            'overall_turnover' => 1
        }
    ),
    '==', 30644.1,
    'Check FLASH, TOUCH, PUT turnover of CR0008, USD'
);

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0010',
        'currency_code'  => 'EUR',
    });

}
'Expect to initialize the object';
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'         => ['INTRAD'],
            'overall_turnover' => 1
        }
    ),
    '==', 100,
    'Check INTRA turnover of CR0010, EUR'
);

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0030',
        'currency_code'  => 'GBP',
    });
}
'Expect to initialize the object';
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'         => ['INTRAD'],
            'overall_turnover' => 1
        }
    ),
    '==', 136.22,
    'Check INTRA turnover of CR0030, GBP'
);

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0030',
        'currency_code'  => 'GBP',
    });
}
'Expect to initialize the object';
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'         => ['INTRAD', 'CALL', 'TOUCH', 'FLASH'],
            'overall_turnover' => 1
        }
    ),
    '==', 564.95,
    'Check INTRAD, CALL, TOUCH, FLASH turnover of CR0030, GBP'
);

throws_ok { $bet_mapper->get_turnover_of_client() } qr/must pass in arguments/, 'get_turnover_for_of_account - Died as no bet types specified';

my $account;
lives_ok {
    my $client = BOM::Platform::Client->new({loginid => 'CR0021'});
    $account = $client->default_account;

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
}
'expecting to create the required account models to buy / sell bet';

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0021',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';

cmp_ok($bet_mapper->get_bet_count_of_client, '==', 67, 'Count number of bets for CR0021 (default currency = USD)');

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0011',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';

my $new_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $new_loginid = $new_client->loginid;

my $currency    = 'USD';
my $new_account = $new_client->set_default_account($currency);

$new_client->payment_free_gift(
    currency => $currency,
    amount   => 10000,
    remark   => 'free gift',
);

my $start_time  = Date::Utility->new->epoch;
my $contract    = produce_contract('FLASHU_R_50_100_' . $start_time . '_5T_S0P_0', 'USD');
my $p           = $contract->build_parameters;
my $tick_params = {
    symbol => 'not_checked',
    epoch  => $start_time,
    quote  => 100
};

my $tick = BOM::Market::Data::Tick->new($tick_params);
$p->{date_pricing} = $start_time;
$p->{current_tick} = $tick;
$contract          = produce_contract($p);
my $transaction = BOM::Product::Transaction->new({
    price         => $contract->ask_price,
    client        => $new_client,
    contract      => $contract,
    comment       => '',
    purchase_date => $contract->date_start,
});
isnt $transaction->buy, 'undef', 'successful buy';

my $start_time_2  = Date::Utility->new->epoch;
my $end_time      = $start_time_2 + 60;
my $contract_2    = produce_contract('FLASHU_R_75_100_' . $start_time_2 . '_' . $end_time . '_S0P_0', 'USD');
my $p_2           = $contract_2->build_parameters;
my $tick_params_2 = {
    symbol => 'not_checked',
    epoch  => $start_time_2,
    quote  => 100
};

my $tick_2 = BOM::Market::Data::Tick->new($tick_params_2);
$p_2->{date_pricing} = $start_time_2;
$p_2->{current_tick} = $tick_2;
$contract_2          = produce_contract($p_2);

my $transaction_2 = BOM::Product::Transaction->new({
    price    => $contract_2->ask_price,
    client   => $new_client,
    contract => $contract_2,
    comment  => ''
});
isnt $transaction_2->buy, 'undef', 'successful buy';

my $start_time_3  = Date::Utility->new->epoch;
my $contract_3    = produce_contract('DIGITMATCH_R_50_200_' . $start_time_3 . '_7T_0_0', 'USD');
my $p_3           = $contract_3->build_parameters;
my $tick_params_3 = {
    symbol => 'not_checked',
    epoch  => $start_time_3,
    quote  => 100
};

my $tick_3 = BOM::Market::Data::Tick->new($tick_params_3);
$p_3->{date_pricing} = $start_time_3;
$p_3->{current_tick} = $tick_3;
$contract_3          = produce_contract($p_3);
my $transaction_3 = BOM::Product::Transaction->new({
    price         => $contract_3->ask_price,
    client        => $new_client,
    contract      => $contract_3,
    comment       => '',
    purchase_date => $contract_3->date_start,
});
isnt $transaction_3->buy, 'undef', 'successful buy';

my $start_time_4  = Date::Utility->new->epoch;
my $contract_4    = produce_contract('ASIANU_R_50_100_' . $start_time_4 . '_7T', 'USD');
my $p_4           = $contract_4->build_parameters;
my $tick_params_4 = {
    symbol => 'not_checked',
    epoch  => $start_time_4,
    quote  => 100
};

my $tick_4 = BOM::Market::Data::Tick->new($tick_params_4);
$p_4->{date_pricing} = $start_time_4;
$p_4->{current_tick} = $tick_4;
$contract_4          = produce_contract($p_4);
my $transaction_4 = BOM::Product::Transaction->new({
    price         => $contract_4->ask_price,
    client        => $new_client,
    contract      => $contract_4,
    comment       => '',
    purchase_date => $contract_4->date_start,
});
isnt $transaction_4->buy, 'undef', 'successful buy';

my $start_time_5 = Date::Utility->new->epoch;
my $end_time_5   = $start_time_5 + 900;
my $contract_5   = produce_contract('FLASHU_GDAXI_100_' . $start_time_5 . '_' . $end_time_5 . '_S0P_0', 'USD');
my $p_5          = $contract_5->build_parameters;

my $tick_params_5 = {
    symbol => 'not_checked',
    epoch  => $start_time_5,
    quote  => 100
};

my $tick_5 = BOM::Market::Data::Tick->new($tick_params_5);
$p_5->{date_pricing} = $start_time_5;
$p_5->{current_tick} = $tick_5;
$p_5->{pricing_vol}  = 0.151867027083599;
my $mock = Test::MockModule->new('BOM::Product::Contract');
# we need a vol for this.
$mock->mock('_validate_volsurface', sub { () });
$contract_5 = produce_contract($p_5);
local $ENV{REQUEST_STARTTIME} = $start_time_5;
my $transaction_5 = BOM::Product::Transaction->new({
    price    => 53.14,
    client   => $new_client,
    contract => $contract_5,
    comment  => '',
});
isnt $transaction_5->buy, 'undef', 'successful buy';

my $start_time_6 = Date::Utility->new->epoch;
my $end_time_6   = $start_time_6 + 900;
my $contract_6   = produce_contract('FLASHU_WLDEUR_100_' . $start_time_6 . '_7T_S0P_0', 'USD');
my $p_6          = $contract_6->build_parameters;

my $tick_params_6 = {
    symbol => 'not_checked',
    epoch  => $start_time_6,
    quote  => 100
};

my $tick_6 = BOM::Market::Data::Tick->new($tick_params_6);
$p_6->{date_pricing} = $start_time_6;
$p_6->{current_tick} = $tick_6;
$contract_6          = produce_contract($p_6);
local $ENV{REQUEST_STARTTIME} = $start_time_6;
my $transaction_6 = BOM::Product::Transaction->new({
    price    => 51.88,
    client   => $new_client,
    contract => $contract_6,
    comment  => '',
});
isnt $transaction_6->buy(skip_validation => 1), 'undef', 'successful buy';

$bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
    'client_loginid' => $new_loginid,
    'currency_code'  => 'USD',
});
cmp_ok($bet_mapper->get_turnover_of_client({'tick_expiry' => 1}), '==', '174.33', 'get_turnover_of_client on tick_trade');
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'    => ['DIGITMATCH', 'DIGITDIFF'],
            'tick_expiry' => 1
        }
    ),
    '==', '20.3',
    'get_turnover_of_client on digit contract'
);
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type'    => ['ASIANU', 'ASIAND'],
            'tick_expiry' => 1
        }
    ),
    '==', '51.46',
    'get_turnover_of_client on asian contract'
);
my @indices_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(market => 'indices');
cmp_ok(
    $bet_mapper->get_turnover_of_client({
            'bet_type' => ['CALL', 'PUT'],
            'symbols'  => \@indices_symbols
        }
    ),
    '==', '53.14',
    'get_turnover_of_client on intraday spot index contract'
);
my @smart_index = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market    => 'indices',
    submarket => 'smart_index'
);
my @smart_fx = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market    => 'forex',
    submarket => 'smart_fx'
);
cmp_ok($bet_mapper->get_turnover_of_client({'symbols' => [@smart_index, @smart_fx]}),
    '==', '51.88', 'get_turnover_of_client on smarties index contract');

# test with acc that does not exist
lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR444444',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0021',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';
cmp_ok(0 + @{$bet_mapper->get_open_bets_of_account()}, '==', 35, 'Check number of open bets');

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'MLT0014',
        'currency_code'  => 'GBP',
    });
}
'Expect to initialize the object';
cmp_ok(0 + @{$bet_mapper->get_open_bets_of_account()}, '==', 2, 'Check number of open bets');

# test with acc that does not exist
lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR444444',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';
cmp_ok(0 + @{$bet_mapper->get_open_bets_of_account()}, '==', 0, 'Check number of open bets');
subtest 'get_fmb_by_id' => sub {
    plan tests => 14;
    my @bet_ids;

    lives_ok {
        for (1 .. 2) {
            my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
                type => 'fmb_higher_lower_buy',
            });
            push @bet_ids, $fmb->id;
        }
    }
    'Added fixture bet successfully';

    is(scalar @bet_ids, 2, 'Expected to add two fmb fixture');

    lives_ok {
        $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
            broker_code => 'CR',
        });
    }
    'Expect to get data mapper for FMB';

    my $result;
    lives_ok {
        $result = $bet_mapper->get_fmb_by_id(\@bet_ids);
    }
    'Successfull run get_fmb_by_id to return array ref';
    is(ref $result,       'ARRAY', 'Expect to get array ref');
    is(scalar @{$result}, 2,       'Correct number of bet returned');

    lives_ok {
        $result = $bet_mapper->get_fmb_by_id(\@bet_ids, 1);
    }
    'Successfull run get_fmb_by_id to return hash ref';
    is(ref $result, 'HASH', 'Expect to get hash ref');

    lives_ok {
        $result = $bet_mapper->get_fmb_by_id([$bet_ids[0]]);
    }
    'Expect to get a model from database by passing only one id';
    isa_ok($result->[0], 'BOM::Database::Model::FinancialMarketBet::HigherLowerBet');

    throws_ok { $result = $bet_mapper->get_fmb_by_id(); } qr/Invalid bet_ids reference/, 'Expect to die by passing invalid param';

    throws_ok { $result = $bet_mapper->get_fmb_by_id($bet_ids[0]); } qr/Only array ref accepted/, 'Expect to die by passing invalid param';

    throws_ok { $result = $bet_mapper->get_fmb_by_id(@bet_ids); } qr/Only array ref accepted/, 'Expect to die by passing invalid param';

    throws_ok { $result = $bet_mapper->get_fmb_by_id({id => 23423423}); } qr/Only array ref accepted/, 'Expect to die by passing invalid param';
};

subtest 'get_sold' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $account = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    my @bets;
    my $date = Date::Utility->new('2014-07-01 00:01:01');
    for my $hour (1 .. 5) {
        my $start_date = $date->plus_time_interval($hour . 'h')->datetime;
        my $end_date   = $date->plus_time_interval(($hour + 5) . 'h')->datetime;
        unshift @bets,
            BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
                type             => 'fmb_higher_lower_sold_won',
                account_id       => $account->id,
                purchase_time    => $start_date,
                transaction_time => $start_date,
                start_time       => $start_date,
                expiry_time      => $end_date,
            });
    }

    my $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

    cmp_deeply([map { $_->{id} } @{$bet_mapper->get_sold()}], [map { $_->id } @bets], 'Got all bets');
    cmp_deeply(
        [map { $_->{id} } @{$bet_mapper->get_sold({after => '2014-07-01 02:00:00'})}],
        [map { $_->id } @bets[0 .. 3]],
        'Got bets after 02:00:00'
    );
    cmp_deeply([
            map { $_->{id} } @{
                $bet_mapper->get_sold({
                        after => '2014-07-01 02:00:00',
                        limit => 2
                    })}
        ],
        [map { $_->id } @bets[2 .. 3]],
        'Got 2 bets after 02:00:00'
    );
    cmp_deeply(
        [map { $_->{id} } @{$bet_mapper->get_sold({before => '2014-07-01 04:02:00'})}],
        [map { $_->id } @bets[1 .. 4]],
        'Got bets before 04:02:00'
    );
    cmp_deeply([
            map { $_->{id} } @{
                $bet_mapper->get_sold({
                        after  => '2014-07-01 02:00:00',
                        before => '2014-07-01 04:02:00'
                    })}
        ],
        [map { $_->id } @bets[1 .. 3]],
        'Got bets between 02:00:00 and 04:02:00'
    );
    is scalar @{$bet_mapper->get_sold({after  => '2014-07-02 00:00:00'})}, 0, "No bets after 2014-07-02";
    is scalar @{$bet_mapper->get_sold({before => '2014-07-01 00:00:00'})}, 0, "No bets before 2014-07-01";
};

use strict;
use warnings;
use Test::Most (tests => 13);
use Test::Warnings;
use Test::MockModule;
use Test::MockTime::HiRes;
use Test::Exception;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Postgres::FeedDB::Spot::Tick;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

initialize_realtime_ticks_db;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new
    }) for qw(EUR USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR0021',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';

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

my $amount_type = 'payout';
my $start_time  = Date::Utility->new->epoch;
my $contract    = produce_contract('CALL_R_50_100_' . $start_time . '_5T_S0P_0', 'USD');
my $p           = $contract->build_parameters;
my $tick_params = {
    symbol => 'not_checked',
    epoch  => $start_time,
    quote  => 100
};

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $tick = Postgres::FeedDB::Spot::Tick->new($tick_params);
$p->{date_pricing} = $start_time;
$p->{current_tick} = $tick;
$contract          = produce_contract($p);

my $transaction = BOM::Transaction->new({
    price         => $contract->ask_price,
    amount_type   => $amount_type,
    client        => $new_client,
    contract      => $contract,
    purchase_date => $contract->date_start,
});
isnt $transaction->buy, 'undef', 'successful buy';

my $start_time_2  = Date::Utility->new->epoch;
my $end_time      = $start_time_2 + 60;
my $contract_2    = produce_contract('CALL_R_75_100_' . $start_time_2 . '_' . $end_time . '_S0P_0', 'USD');
my $p_2           = $contract_2->build_parameters;
my $tick_params_2 = {
    symbol => 'not_checked',
    epoch  => $start_time_2,
    quote  => 100
};

my $tick_2 = Postgres::FeedDB::Spot::Tick->new($tick_params_2);
$p_2->{date_pricing} = $start_time_2;
$p_2->{current_tick} = $tick_2;
$contract_2          = produce_contract($p_2);

my $transaction_2 = BOM::Transaction->new({
    price         => $contract_2->ask_price,
    client        => $new_client,
    contract      => $contract_2,
    purchase_date => $start_time_2,
    amount_type   => $amount_type,
});
my $b = $transaction_2->buy;

isnt $transaction_2->buy, 'undef', 'successful buy';

my $start_time_3  = Date::Utility->new->epoch;
my $contract_3    = produce_contract('DIGITMATCH_R_50_200_' . $start_time_3 . '_7T_0_0', 'USD');
my $p_3           = $contract_3->build_parameters;
my $tick_params_3 = {
    symbol => 'not_checked',
    epoch  => $start_time_3,
    quote  => 100
};

my $tick_3 = Postgres::FeedDB::Spot::Tick->new($tick_params_3);
$p_3->{date_pricing} = $start_time_3;
$p_3->{current_tick} = $tick_3;
$contract_3          = produce_contract($p_3);
my $transaction_3 = BOM::Transaction->new({
    price         => $contract_3->ask_price,
    client        => $new_client,
    amount_type   => $amount_type,
    contract      => $contract_3,
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

my $tick_4 = Postgres::FeedDB::Spot::Tick->new($tick_params_4);
$p_4->{date_pricing} = $start_time_4;
$p_4->{current_tick} = $tick_4;
$contract_4          = produce_contract($p_4);
my $transaction_4 = BOM::Transaction->new({
    price         => $contract_4->ask_price,
    client        => $new_client,
    amount_type   => $amount_type,
    contract      => $contract_4,
    purchase_date => $contract_4->date_start,
});
isnt $transaction_4->buy, 'undef', 'successful buy';
my $start_time_5 = Date::Utility->new('2015-11-10 08:30:00')->epoch;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => Date::Utility->new($start_time_5),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($start_time_5),
    }) for qw(EUR USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new($start_time_5),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new($start_time_5),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => Date::Utility->new($start_time_5),
    });

my $end_time_5 = $start_time_5 + 900;
my $contract_5 = produce_contract('CALL_GDAXI_100_' . $start_time_5 . '_' . $end_time_5 . '_S0P_0', 'USD');
my $p_5        = $contract_5->build_parameters;

my $tick_params_5 = {
    symbol => 'not_checked',
    epoch  => $start_time_5,
    quote  => 100
};
my $tick_5 = Postgres::FeedDB::Spot::Tick->new($tick_params_5);
$p_5->{date_pricing} = $start_time_5;
$p_5->{current_tick} = $tick_5;
$p_5->{pricing_vol}  = 0.151867027083599;
my $mock = Test::MockModule->new('BOM::Product::Contract');
# we need a vol for this.
$mock->mock('_validate_input_parameters', sub { () });
$mock->mock('_validate_volsurface',       sub { () });
$contract_5 = produce_contract($p_5);
set_absolute_time($start_time_5);
my $transaction_5 = BOM::Transaction->new({
    price         => 70,
    client        => $new_client,
    contract      => $contract_5,
    amount_type   => $amount_type,
    purchase_date => $start_time_5,
});

isnt $transaction_5->buy, 'undef', 'successful buy';
restore_time;
my $start_time_6 = Date::Utility->new->epoch;
my $end_time_6   = $start_time_6 + 900;
my $contract_6   = produce_contract('CALL_WLDEUR_100_' . $start_time_6 . '_7T_S0P_0', 'USD');
my $p_6          = $contract_6->build_parameters;

my $tick_params_6 = {
    symbol => 'not_checked',
    epoch  => $start_time_6,
    quote  => 100
};

my $tick_6 = Postgres::FeedDB::Spot::Tick->new($tick_params_6);
$p_6->{date_pricing} = $start_time_6;
$p_6->{current_tick} = $tick_6;
$contract_6          = produce_contract($p_6);
my $transaction_6 = BOM::Transaction->new({
    price         => 51.88,
    client        => $new_client,
    contract      => $contract_6,
    purchase_date => $start_time_6,
    amount_type   => $amount_type,
});
isnt $transaction_6->buy(skip_validation => 1), 'undef', 'successful buy';

$bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
    'client_loginid' => $new_loginid,
    'currency_code'  => 'USD',
});
my @indices_symbols = create_underlying_db->get_symbols_for(market => 'indices');
my @smart_index = create_underlying_db->get_symbols_for(
    market    => 'indices',
    submarket => 'smart_index'
);
my @smart_fx = create_underlying_db->get_symbols_for(
    market    => 'forex',
    submarket => 'smart_fx'
);

# test with acc that does not exist
lives_ok {
    $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        'client_loginid' => 'CR444444',
        'currency_code'  => 'USD',
    });
}
'Expect to initialize the object';

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
                settlement_time  => $end_date,
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

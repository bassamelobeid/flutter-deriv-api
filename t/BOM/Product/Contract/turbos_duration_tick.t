#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Config::Runtime;

initialize_realtime_ticks_db();
my $now    = Date::Utility->new('10-Mar-2015');
my $symbol = 'R_100';
my $epoch  = $now->epoch;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'TURBOSLONG',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 100,
    barrier      => '-73.00',
};

subtest 'tick duration contract close tick undef' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [10138.979, $now->epoch,     $symbol],
        [10239.829, $now->epoch + 1, $symbol],
        [10299.666, $now->epoch + 2, $symbol],
        [10308.777, $now->epoch + 3, $symbol],
        [10333.888, $now->epoch + 4, $symbol],
        [10388.321, $now->epoch + 5, $symbol],
    );

    $args->{underlying}   = $symbol;
    $args->{duration}     = '5t';
    $args->{date_pricing} = $now->plus_time_interval('5s');
    my $c = produce_contract($args);
    ok defined($c->entry_tick), 'entry tick defined';
    is $c->entry_tick->epoch, $now->epoch, 'entry tick epoch';
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price,        '428.09',        'win payoff';
    is $c->exit_tick->epoch, $now->epoch + 5, 'exit tick epoch';

    # checking close tick return undef and not return tick from sell time
    is $c->close_tick, undef, 'close tick should be undefined';
};

subtest 'tick duration contract start tick before start date' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [10111.321, $now->epoch - 1, $symbol],
        [10138.979, $now->epoch,     $symbol],
        [10239.829, $now->epoch + 1, $symbol],
        [10299.666, $now->epoch + 2, $symbol],
        [10308.777, $now->epoch + 3, $symbol],
        [10333.888, $now->epoch + 4, $symbol],
        [10388.321, $now->epoch + 5, $symbol],
    );

    my $args1 = {%$args};
    $args1->{underlying}   = $symbol;
    $args1->{duration}     = '5t';
    $args1->{date_pricing} = $now->plus_time_interval('5s');
    $args1->{entry_epoch}  = $now->epoch - 1;
    my $c = produce_contract($args1);
    ok defined($c->entry_tick), 'entry tick defined';
    is $c->entry_tick->epoch, $now->epoch - 1, 'entry tick epoch';
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price,        '392.56',        'win payoff';
    is $c->exit_tick->epoch, $now->epoch + 4, 'exit tick epoch';
};

subtest 'tick duration contract close tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([10138.979, $now->epoch, $symbol], [10239.829, $now->epoch + 1, $symbol],);

    $args->{underlying}   = $symbol;
    $args->{duration}     = '5t';
    $args->{date_pricing} = $now->plus_time_interval('2s');
    my $c = produce_contract($args);
    is $c->current_tick->epoch, $now->epoch + 1, 'correct tick';
    is $c->bid_price,           '227.80',        'has bid price';

    # add tick
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 2,
        quote      => 11239.829,
    });

    # close tick undefed when sell_price is undefined
    $args->{date_pricing} = $now->plus_time_interval('3s');
    $c = produce_contract($args);
    is $c->sell_price,                           undef, 'sell_price is undefined';
    is $c->close_tick,                           undef, 'close tick is undefined';
    is defined $c->audit_details->{'all_ticks'}, 1,     'audit_details is defined';
    ok !$c->is_expired, 'not expired';
    is $c->bid_price, '1555.58', 'has higher bid price';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 3,
        quote      => 12239.829,
    });

    $args->{date_pricing} = $now->plus_time_interval('4s');
    $c = produce_contract($args);

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 4,
        quote      => 13239.829,
    });

    $args->{date_pricing} = $now->plus_time_interval('5s');
    $c = produce_contract($args);

    # tick 5
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 5,
        quote      => 13245.112,
    });

    # checking close tick return undef and not return tick from sell time
    is $c->close_tick, undef, 'close tick should be undefined';

    # verify audit exit spot in correct tick
    my $exit_spot = $c->audit_details->{'all_ticks'}[5]{'name'}[2];
    is $exit_spot, "Exit Spot", "Contract exit in correct tick";
};

subtest 'audit_details exit spot in correct tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [10138.979, $now->epoch,     $symbol],
        [10239.829, $now->epoch + 1, $symbol],
        [10299.666, $now->epoch + 2, $symbol],
        [10308.777, $now->epoch + 3, $symbol],
        [10333.888, $now->epoch + 4, $symbol],
        [10388.321, $now->epoch + 5, $symbol],
        [10398.621, $now->epoch + 6, $symbol],
        [10399.999, $now->epoch + 7, $symbol],
    );

    $args->{underlying}   = $symbol;
    $args->{duration}     = '5t';
    $args->{date_pricing} = $now->plus_time_interval('5s');
    my $c = produce_contract($args);
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price, '428.09', 'win payoff';

    # checking close tick return undef and not return tick from sell time
    is $c->close_tick, undef, 'close tick should be undefined';

    # verify audit exit spot in correct tick
    my $exit_spot = $c->audit_details->{'all_ticks'}[5]{'name'}[2];
    is $exit_spot, "Exit Spot", "Contract exit in correct tick";
};

$now    = Date::Utility->new('18-Jan-2024');
$symbol = '1HZ25V';
$epoch  = $now->epoch;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

$args = {
    bet_type     => 'TURBOSLONG',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 28,
    barrier      => '-243082.23',
};

subtest 'number of contracts after roundcommon change to rounddown' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([485812.86, $now->epoch, $symbol],);

    $args->{underlying}   = $symbol;
    $args->{duration}     = '5t';
    $args->{date_pricing} = $now;

    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    is $c->number_of_contracts, '0.000115', 'correct number_of_contracts';

};

subtest 'number of contracts after roundcommon change to rounddown crypto' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([485812.86, $now->epoch, $symbol],);

    my $base                     = 'USD';
    my $target_currency          = 'BTC';
    my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
    $mocked_CurrencyConverter->mock(
        'in_usd',
        sub {
            my $price         = shift;
            my $from_currency = shift;

            $from_currency eq 'BTC' and return 5500 * $price;
            $from_currency eq 'USD' and return 1 * $price;
            return 0;
        });

    $args->{currency}     = 'BTC';
    $args->{underlying}   = $symbol;
    $args->{duration}     = '5t';
    $args->{date_pricing} = $now;
    my $c = produce_contract($args);

    ok $c->pricing_new, 'this is a new contract';
    is $c->number_of_contracts, '0.000115178135', 'correct number_of_contracts';

};

done_testing();

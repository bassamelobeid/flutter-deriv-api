use strict;
use warnings;

use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Product::ContractFactory qw( produce_contract );
use Cache::RedisDB;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => Date::Utility->new('2008-02-18'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new('2008-02-13'),
    }) for qw(frxUSDJPY frxEURUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new('2008-02-18'),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new('2008-02-29'),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new('2008-02-18'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new('2008-02-13'),
    }) for qw(USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new('2008-02-18'),
    }) for qw(EUR EUR-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new('2008-02-18'),
    });

subtest 'FOREX settlement check on Wednesday' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1200614400,    #entry tick
        quote      => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202860800,    # open tick of 13-Feb-08
        quote      => 105,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202861800,    # second tick of 13-Feb-08
        quote      => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202862800,    # third tick of 13-Feb-08
        quote      => 105.5,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202936400,    # tick at 2008-02-13 21:00:00
        quote      => 108,
    });

    my $bet_params = {
        bet_type     => 'CALL',
        date_expiry  => Date::Utility->new('13-Feb-08')->plus_time_interval('21h00m00s'),    # 107.36 108.38 106.99 108.27
        date_start   => '18-Jan-08',                                                         # 106.42 107.59 106.38 106.88
        date_pricing => Date::Utility->new('13-Feb-08')->plus_time_interval('22h00m00s'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 109,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_expired, 'is expired';
    ok !$bet->is_valid_to_sell, 'is not valid to sell';
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    is($bet->exit_tick->quote,                  '108',                    'exit tick is 108');
    is($bet->exit_tick->epoch,                  '1202936400',             'the exit tick is the one at 21:00');
    cmp_ok($bet->bid_price, '==', 0, 'Indicative outcome is 0 as the exit tick is 108');

    my $bet_params_2 = {
        bet_type     => 'ONETOUCH',
        date_expiry  => Date::Utility->new('13-Feb-08')->plus_time_interval('21h00m00s'),    # 107.36 108.38 106.99 108.27
        date_start   => '18-Jan-08',                                                         # 106.42 107.59 106.38 106.88
        date_pricing => Date::Utility->new('13-Feb-08')->plus_time_interval('22h00m00s'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 109,
    };
    my $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired, 'is expired';
    ok !$bet_2->is_valid_to_sell, 'is not valid to sell';
    ok $bet_2->is_after_expiry, 'is after expiry';
    ok !$bet_2->is_after_settlement, 'is not pass settlement time';
    is($bet_2->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    is($bet_2->exit_tick->quote,                  '108',                    'exit tick is 108');
    is($bet_2->exit_tick->epoch,                  '1202936400',             'the exit tick is the one at 21:00');
    cmp_ok($bet_2->bid_price, '==', 0, 'Indicative outcome is 0 as the high is 108');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202947199,    # 13 Feb 2008 23:59:59
        quote      => 109.5,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202947200,    #14 Feb 2008 00:00:00
        quote      => 110,
    });

    $bet_params->{date_pricing} = Date::Utility->new('13-Feb-08 23:59:59');
    $bet = produce_contract($bet_params);
    ok $bet->is_expired,          'is expired';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    is($bet->exit_tick->quote, '109.5',    'exit tick is 109.5');
    is($bet->exit_tick->epoch, 1202947199, 'the exit tick is the one at 23:59:59');
    cmp_ok($bet->bid_price, '==', 1, 'Correct expiration with full payout as the exit tick is 109.5');

    $bet_params_2->{date_pricing} = Date::Utility->new('13-Feb-08 23:59:59');
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired,          'is expired';
    ok $bet_2->is_valid_to_sell,    'is valid to sell';
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is not pass settlement time';
    is($bet_2->exit_tick->quote, '109.5',      'exit tick is 109.5');
    is($bet_2->exit_tick->epoch, '1202947199', 'the exit tick is the one at 23:59:59');
    cmp_ok($bet_2->bid_price, '==', 1, 'Indicative outcome is 1 as the high is 109.5');

};
subtest 'FOREX settlement check on Friday' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203033600,    # open tick of 15-Feb-08
        quote      => 104,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203034000,    # second tick of 15-Feb-08
        quote      => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203036200,    # third tick of 15-Feb-08
        quote      => 105.5,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203109200,    # tick at 2008-02-15 21:00:00
        quote      => 108,
    });

    my $bet_params = {
        bet_type     => 'CALL',
        date_expiry  => Date::Utility->new('2008-02-15 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-15 21:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 109,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_expired, 'is expired';
    ok !$bet->is_valid_to_sell, 'is not valid to sell';
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    is($bet->exit_tick->quote,                  '108',                    'exit tick is 108');
    is($bet->exit_tick->epoch,                  '1203109200',             'the exit tick is the one at 21:00');
    cmp_ok($bet->bid_price, '==', 0, 'Indicative outcome with zero price as the exit tick is 108');

    my $bet_params_2 = {
        bet_type     => 'NOTOUCH',
        date_expiry  => Date::Utility->new('2008-02-15 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-15 21:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 120,
    };
    my $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired, 'is expired';
    ok !$bet_2->is_valid_to_sell, 'is not valid to sell';
    ok $bet_2->is_after_expiry, 'is after expiry';
    ok !$bet_2->is_after_settlement, 'is not pass settlement time';
    is($bet_2->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    is($bet_2->exit_tick->quote,                  '108',                    'exit tick is 108');
    is($bet_2->exit_tick->epoch,                  '1203109200',             'the exit tick is the one at 21:00');
    cmp_ok($bet_2->bid_price, '==', 1, 'Indicative outcome with full payout as the high is 110');

    $bet_params->{date_pricing} = Date::Utility->new('2008-02-16 00:00:00');    # sat morning
    $bet = produce_contract($bet_params);
    ok $bet->is_expired, 'is expired';
    ok !$bet->is_valid_to_sell, 'is not valid to sell';
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    is($bet->primary_validation_error->message, 'exit tick is inconsistent', 'Not valid to sell as it is waiting for exit tick');
    is($bet->exit_tick->quote, '108', 'exit tick is 108');

    $bet_params_2->{date_pricing} = Date::Utility->new('2008-02-16 00:00:00');    # sat morning
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired, 'is not expired';
    ok !$bet_2->is_valid_to_sell, 'is not valid to sell';
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is pass settlement time';
    is($bet_2->primary_validation_error->message, 'exit tick is inconsistent', 'Not valid to sell as it is waiting for exit tick');
    is($bet_2->exit_tick->quote, '108', 'exit tick is 108');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203292800,                                             # tick at 2008-02-18 00:00:00
        quote      => 110,
    });

    $bet_params->{date_pricing} = Date::Utility->new('2008-02-18 00:00:00');      #Call contract on Monday morning
    $bet = produce_contract($bet_params);
    ok $bet->is_expired,          'is expired';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    is($bet->exit_tick->quote, '108',        'exit tick is 108');
    is($bet->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    cmp_ok($bet->bid_price, '==', 0, 'Correct expiration with zero price as the exit tick is 108');

    $bet_params_2->{date_pricing} = Date::Utility->new('2008-02-18 00:00:00');    #No touch contract on Monday morning
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired,          'is expired';
    ok $bet_2->is_valid_to_sell,    'is valid to sell';
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is pass settlement time';
    is($bet_2->exit_tick->quote, '108',        'exit tick is 108');
    is($bet_2->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    cmp_ok($bet_2->bid_price, '==', 1, 'Correct expiration with full payout as the high is 110');
};

subtest 'Index settlement check on ' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => 1203322200,    #entry tick
        quote      => 1000,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => 1203408600,    # open tick of 19-02-08
        quote      => 1005,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => 1203409200,    # second tick of 19-02-08
        quote      => 1006,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => 1203423000,    # third tick of 19-02-08
        quote      => 1010,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => 1203438600,    # tick at 19-02-08 16:30
        quote      => 1008,
    });

    my $bet_params = {
        bet_type     => 'CALL',
        date_expiry  => Date::Utility->new('2008-02-19 16:30:00'),
        date_start   => Date::Utility->new('2008-02-18 08:00:00'),
        date_pricing => Date::Utility->new('2008-02-19 16:30:30'),
        underlying   => 'GDAXI',
        payout       => 1,
        currency     => 'USD',
        barrier      => 1004,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_expired, 'is expired';
    ok !$bet->is_valid_to_sell, 'is not valid to sell';
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    is($bet->exit_tick->quote,                  '1008',                   'exit tick is 1008');
    is($bet->exit_tick->epoch,                  '1203438600',             'the exit tick is the one at 16:30');
    cmp_ok($bet->bid_price, '==', 1, 'Indicative outcome with full payout as the exit tick is 1008');

    BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            underlying => 'GDAXI',
            epoch      => 1203379200,    # 19 Feb 2008 00:00:00 GMT
            open       => 1008,
            high       => 1110,
            low        => 1002,
            close      => 1003,
            official   => 1,

    });
    $bet_params->{date_pricing} = Date::Utility->new('2008-02-19 19:30:00');
    $bet = produce_contract($bet_params);
    ok $bet->is_expired,          'is expired';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    is($bet->exit_tick->quote, '1003',     'exit tick is 1003');
    is($bet->exit_tick->epoch, 1203438600, 'the exit tick is the one at 16:30:00');
    cmp_ok($bet->bid_price, '==', 0, 'Correct expiration with full payout as the exit tick is 1003');

};
subtest 'Path dependent contracts settlement check' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203298200,    # open tick of 18-Feb-08
        quote      => 104,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203298600,    # second tick of 18-Feb-08
        quote      => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203299000,    # third tick of 18-Feb-08
        quote      => 110,
    });

    my $bet_params = {
        bet_type     => 'ONETOUCH',
        date_expiry  => Date::Utility->new('2008-02-29 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-18 01:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 109,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_expired,       'is expired';
    ok $bet->is_valid_to_sell, 'is valid to sell';
    ok !$bet->is_after_expiry,     'is after expiry';
    ok !$bet->is_after_settlement, 'no after settlement time';
    cmp_ok($bet->bid_price, '==', 1, 'Bid price is full payout as the barrier touched');

    my $bet_params_2 = {
        bet_type     => 'NOTOUCH',
        date_expiry  => Date::Utility->new('2008-02-29 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-18 01:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 109,
    };
    my $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_expired,       'is expired';
    ok $bet_2->is_valid_to_sell, 'is valid to sell';
    ok !$bet_2->is_after_expiry,     'no after expiry';
    ok !$bet_2->is_after_settlement, 'no after settlement time';
    cmp_ok($bet_2->bid_price, '==', 0, 'Bid price is zero as the barrier touched');

    my $bet_params_3 = {
        bet_type     => 'NOTOUCH',
        date_expiry  => Date::Utility->new('2008-02-29 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-18 01:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 120,
    };

    my $bet_3 = produce_contract($bet_params_3);
    ok !$bet_3->is_expired, 'is not expired';
    ok $bet_3->is_valid_to_sell, 'is valid to sell';
    ok !$bet_3->is_after_expiry,     'is not after expiry';
    ok !$bet_3->is_after_settlement, 'is not pass settlement';
    is($bet_3->bid_price, '0.95', 'Bid price');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1204245000,    # first tick of 29-Feb
        quote      => 110,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1204255000,    # second tick of 29-Feb
        quote      => 115,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1204265000,    # third tick of 29-Feb
        quote      => 112,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1204317000,    # last tick of 29-Feb
        quote      => 110,
    });

    $bet_params_3->{date_pricing} = Date::Utility->new('2008-02-29 21:00:01');    # Friday evening
    $bet_3 = produce_contract($bet_params_3);
    ok $bet_3->is_expired, 'is  expired';
    ok !$bet_3->is_valid_to_sell, 'is not valid to sell';
    ok $bet_3->is_after_expiry, 'is after expiry';
    ok !$bet_3->is_after_settlement, 'is not pass settlement time';
    is($bet_3->primary_validation_error->message, 'waiting for settlement');
    is($bet_3->exit_tick->quote, '110', 'exit tick is last available tick');

    $bet_params_3->{date_pricing} = Date::Utility->new('2008-03-01 00:00:00');    # Sat Morning
    $bet_3 = produce_contract($bet_params_3);
    ok $bet_3->is_expired, 'is expired';
    ok !$bet_3->is_valid_to_sell, 'is not valid to sell';
    ok $bet_3->is_after_expiry,     'is after expiry';
    ok $bet_3->is_after_settlement, 'is pass settlement time';
    is($bet_3->primary_validation_error->message, 'exit tick is inconsistent', 'Not valid to sell as it is waiting for exit tick');
    is($bet_3->exit_tick->quote, '110', 'exit tick is last availble tick');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1204502400,                                             # First tick of 03-03
        quote      => 125,
    });

    $bet_params_3->{date_pricing} = Date::Utility->new('2008-03-03 00:00:00');    # Monday morning
    $bet_3 = produce_contract($bet_params_3);
    ok $bet_3->is_expired,          'is expired';
    ok $bet_3->is_valid_to_sell,    'is valid to sell';
    ok $bet_3->is_after_expiry,     'is after expiry';
    ok $bet_3->is_after_settlement, 'is pass settlement time';
    is($bet_3->exit_tick->quote, '110',        'exit tick is 110');
    is($bet_3->exit_tick->epoch, '1204318800', 'the exit tick is the one at 21:00');
    cmp_ok($bet_3->bid_price, '==', 1, 'Correct expiration with full payout as barrier not touch');

};

done_testing;

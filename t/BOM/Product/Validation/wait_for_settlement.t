use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

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
        for_sale     => 1,
        barrier      => 109,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    ok !$bet->is_valid_to_sell,    'is not valid to sell';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    ok $bet->is_expired, 'is expired';
    is($bet->exit_tick->quote, '108',        'exit tick is 108');
    is($bet->exit_tick->epoch, '1202936400', 'the exit tick is the one at 21:00');
    is($bet->bid_price,        0,            'Indicative outcome is 0 as the exit tick is 108');

    my $bet_params_2 = {
        bet_type     => 'ONETOUCH',
        date_expiry  => Date::Utility->new('13-Feb-08')->plus_time_interval('21h00m00s'),    # 107.36 108.38 106.99 108.27
        date_start   => '18-Jan-08',                                                         # 106.42 107.59 106.38 106.88
        date_pricing => Date::Utility->new('13-Feb-08')->plus_time_interval('22h00m00s'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        for_sale     => 1,
        barrier      => 109,
    };
    my $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_after_expiry, 'is after expiry';
    ok !$bet_2->is_after_settlement, 'is not pass settlement time';
    ok !$bet_2->is_valid_to_sell,    'is not valid to sell';
    is($bet_2->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    ok $bet_2->is_expired, 'is expired';
    is($bet_2->exit_tick->quote, '108',        'exit tick is 108');
    is($bet_2->exit_tick->epoch, '1202936400', 'the exit tick is the one at 21:00');
    is($bet_2->bid_price,        0,            'Indicative outcome is 0 as the high is 108');

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
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_expired,          'is expired';
    is($bet->exit_tick->quote, '109.5',    'exit tick is 109.5');
    is($bet->exit_tick->epoch, 1202947199, 'the exit tick is the one at 23:59:59');
    is($bet->bid_price,        1,          'Correct expiration with full payout as the exit tick is 109.5');

    $bet_params_2->{date_pricing} = Date::Utility->new('13-Feb-08 23:59:59');
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is not pass settlement time';
    ok $bet_2->is_valid_to_sell,    'is not valid to sell';
    ok $bet_2->is_expired,          'is expired';
    is($bet_2->exit_tick->quote, '109.5',      'exit tick is 109.5');
    is($bet_2->exit_tick->epoch, '1202947199', 'the exit tick is the one at 23:59:59');
    is($bet_2->bid_price,        1,            'Indicative outcome is 1 as the high is 109.5');

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
        for_sale     => 1,
        barrier      => 109,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    ok !$bet->is_valid_to_sell,    'is not valid to sell';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    ok $bet->is_expired, 'is expired';
    is($bet->exit_tick->quote, '108',        'exit tick is 108');
    is($bet->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    is($bet->bid_price,        0,            'Indicative outcome with zero price as the exit tick is 108');

    my $bet_params_2 = {
        bet_type     => 'NOTOUCH',
        date_expiry  => Date::Utility->new('2008-02-15 21:00:00'),
        date_start   => '18-Jan-08',
        date_pricing => Date::Utility->new('2008-02-15 21:30:00'),
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        for_sale     => 1,
        barrier      => 120,
    };
    my $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_after_expiry, 'is after expiry';
    ok !$bet_2->is_after_settlement, 'is not pass settlement time';
    ok !$bet_2->is_valid_to_sell,    'is not valid to sell';
    is($bet_2->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    ok $bet_2->is_expired, 'is expired';
    is($bet_2->exit_tick->quote, '108',        'exit tick is 108');
    is($bet_2->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    is($bet_2->bid_price,        1,            'Indicative outcome with full payout as the high is 110');

    $bet_params->{date_pricing} = Date::Utility->new('2008-02-16 00:00:00');    # sat morning
    $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    ok !$bet->is_valid_to_sell, 'is not valid to sell';
    is($bet->primary_validation_error->message, 'exit tick is undefined', 'Not valid to sell as it is waiting for exit tick');
    ok !$bet->is_expired, 'is not expired';
    is($bet->exit_tick, undef, 'exit tick is undef');

    $bet_params_2->{date_pricing} = Date::Utility->new('2008-02-16 00:00:00');    # sat morning
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is pass settlement time';
    ok !$bet_2->is_valid_to_sell, 'is not valid to sell';
    is($bet_2->primary_validation_error->message, 'exit tick is undefined', 'Not valid to sell as it is waiting for exit tick');
    ok !$bet_2->is_expired, 'is not expired';
    is($bet_2->exit_tick, undef, 'exit tick is undef');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1203292800,                                             # tick at 2008-02-18 00:00:00
        quote      => 110,
    });

    $bet_params->{date_pricing} = Date::Utility->new('2008-02-18 00:00:00');      # Monday morning
    $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_expired,          'is expired';
    is($bet->exit_tick->quote, '108',        'exit tick is 108');
    is($bet->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    is($bet->bid_price,        0,            'Correct expiration with zero price as the exit tick is 108');

    $bet_params_2->{date_pricing} = Date::Utility->new('2008-02-18 00:00:00');    # Monday morning
    $bet_2 = produce_contract($bet_params_2);
    ok $bet_2->is_after_expiry,     'is after expiry';
    ok $bet_2->is_after_settlement, 'is pass settlement time';
    ok $bet_2->is_valid_to_sell,    'is valid to sell';
    ok $bet_2->is_expired,          'is expired';
    is($bet_2->exit_tick->quote, '108',        'exit tick is 108');
    is($bet_2->exit_tick->epoch, '1203109200', 'the exit tick is the one at 21:00');
    is($bet_2->bid_price,        1,            'Correct expiration with full payout as the high is 110');
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
        for_sale     => 1,
        barrier      => 1004,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry, 'is after expiry';
    ok !$bet->is_after_settlement, 'is not pass settlement time';
    ok !$bet->is_valid_to_sell,    'is not valid to sell';
    is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
    ok $bet->is_expired, 'is expired';
    is($bet->exit_tick->quote, '1008',       'exit tick is 1008');
    is($bet->exit_tick->epoch, '1203438600', 'the exit tick is the one at 16:30');
    is($bet->bid_price,        1,            'Indicative outcome with full payout as the exit tick is 1008');

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
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_expired,          'is expired';
    is($bet->exit_tick->quote, '1003',     'exit tick is 1003');
    is($bet->exit_tick->epoch, 1203438600, 'the exit tick is the one at 16:30:00');
    is($bet->bid_price,        0,          'Correct expiration with full payout as the exit tick is 1003');

};

done_testing;

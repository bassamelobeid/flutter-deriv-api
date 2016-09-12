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
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new,
    });

subtest 'settlement check' => sub {

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1200614400,    #entry tick
        quote      => 106,
        bid        => 106,
        ask        => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202860800,    # open tick of 13-Feb-08
        quote      => 105,
        bid        => 105,
        ask        => 105,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202861800,    # second tick of 13-Feb-08
        quote      => 106,
        bid        => 106,
        ask        => 106,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202862800,    # third tick of 13-Feb-08
        quote      => 105.5,
        bid        => 105.5,
        ask        => 105.5,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202936400,    # tick at 2008-02-13 21:00:00
        quote      => 108,
        bid        => 108,
        ask        => 108,
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
    is($bet->value,            0,            'Correct expiration with zero price as the exit tick is 108');

    my $opposite = $bet->opposite_contract;
    ok !$opposite->is_valid_to_sell, 'is not valid to sell';
    is($opposite->primary_validation_error->message, 'waiting for settlement', 'Error msg');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202947199,
        quote      => 109.5,
        bid        => 109.5,
        ask        => 109.5,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1202947200,
        quote      => 107,
        bid        => 107,
        ask        => 107,
    });
    $bet_params->{date_pricing} = Date::Utility->new('13-Feb-08 23:59:59');
    $bet = produce_contract($bet_params);
    ok $bet->is_after_expiry,     'is after expiry';
    ok $bet->is_after_settlement, 'is pass settlement time';
    ok $bet->is_valid_to_sell,    'is valid to sell';
    ok $bet->is_expired,          'is expired';
    is($bet->exit_tick->quote, '109.5',    'exit tick is 109.5');
    is($bet->exit_tick->epoch, 1202947199, 'the exit tick is the one at 23:59:59');
    is($bet->value,            1,          'Correct expiration with full payout as the exit tick is 109.5');

};

done_testing;

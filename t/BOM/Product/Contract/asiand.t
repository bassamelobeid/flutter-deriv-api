#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now    = Date::Utility->new('10-Mar-2015');
my $symbol = 'R_100';
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => 'USD',
    });

my $args = {
    bet_type     => 'ASIAND',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    payout       => 10,
};

subtest 'ASIAND' => sub {
    subtest 'config' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol]);
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Asiand';
        is $c->code,            'ASIAND', 'code ASIAND';
        is $c->category_code,   'asian',  'category asian';
        is $c->other_side_code, 'ASIANU', 'other side code ASIANU';
        ok !$c->is_path_dependent, 'not path dependent';
        is $c->tick_count,      5, 'tick count is 5';
        is $c->ticks_to_expiry, 5, 'ticks to expiry is 5';
        isa_ok $c->pricing_engine, 'Pricing::Engine::BlackScholes';
        is $c->shortcode, 'ASIAND_R_100_10_' . $now->epoch . '_5T', 'shortcode is correct';
    };

    $args->{date_pricing} = $now->plus_time_interval('10s');
    subtest 'barrier' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch,     $symbol],
            [100, $now->epoch + 1, $symbol],
            [100, $now->epoch + 2, $symbol],
            [100, $now->epoch + 3, $symbol],
            [100, $now->epoch + 4, $symbol]);
        my $c = produce_contract($args);
        # this is for display purposes
        ok $c->barrier, 'barrier is defined without enough tick';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch,     $symbol],
            [100, $now->epoch + 1, $symbol],
            [100, $now->epoch + 2, $symbol],
            [100, $now->epoch + 3, $symbol],
            [100, $now->epoch + 4, $symbol],
            [105, $now->epoch + 5, $symbol]);
        $c = produce_contract($args);
        ok $c->barrier, 'barrier is defined';
        is $c->barrier->as_absolute, '101.000', 'barrier is the average';
        ok $c->is_expired, 'is expired';
    };
};

done_testing();

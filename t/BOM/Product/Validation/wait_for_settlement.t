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

test_with_feed(
    [['2008-01-18', 106.42, 107.59, 106.38, 106.88], ['2008-02-13', 107.36, 108.38, 106.99, 108.27]],
    'Call Expire daily' => sub {

        my $bet_params = {
            bet_type     => 'CALL',
            date_expiry  => Date::Utility->new('13-Feb-08')->plus_time_interval('21h00m00s'),    # 107.36 108.38 106.99 108.27
            date_start   => '18-Jan-08',                                                         # 106.42 107.59 106.38 106.88
            date_pricing => Date::Utility->new('13-Feb-08')->plus_time_interval('22h00m00s'),
            underlying   => 'frxUSDJPY',
            payout       => 1,
            currency     => 'USD',
            for_sale     => 1,
        };

        # Closing price on 13-Feb-08 is 108.27
        my %barrier_win_map = (
            109 => 0,
        );

        foreach my $barrier (keys %barrier_win_map) {
            $bet_params->{barrier} = $barrier;
            my $bet = produce_contract($bet_params);
            ok $bet->is_after_expiry, 'is after expiry';
            ok !$bet->is_after_settlement, 'is not pass settlement time';
            ok !$bet->is_valid_to_sell,    'is not valid to sell';
            is($bet->primary_validation_error->message, 'waiting for settlement', 'Not valid to sell as it is waiting for settlement');
            ok $bet->is_expired, 'is expired';
            is($bet->value, $barrier_win_map{$barrier}, 'Correct expiration for strike of ' . $barrier);

            my $opposite = $bet->opposite_contract;
            ok !$opposite->is_valid_to_sell, 'is not valid to sell';
            is($opposite->primary_validation_error->message, 'waiting for settlement', 'Error msg');
        }

    });

sub test_with_feed {
    my $setup    = shift;
    my $testname = shift;
    my $test     = shift;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    foreach my $entry (@$setup) {
        my $date = Date::Utility->new($entry->[0]);
        my $param_hash;
        if (scalar @$entry > 3) {
            #un-official ohlc
            $param_hash->{epoch}      = ($date->epoch + 1);
            $param_hash->{quote}      = $entry->[1];
            $param_hash->{underlying} = $entry->[5] if (scalar @$entry == 6);
            #note "Inserting OHLC " . $entry->[0] . "\n";
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 2000);
            $param_hash->{quote} = $entry->[2];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 4000);
            $param_hash->{quote} = $entry->[3];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 8000);
            $param_hash->{quote} = $entry->[4];

            $param_hash->{epoch} = ($date->epoch + 86399);
            $param_hash->{quote} = $entry->[4];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);

            $param_hash->{epoch} = ($date->epoch + 86400);
            $param_hash->{quote} = $entry->[4];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
        } else {
            #note "Inserting " . $entry->[0] . "\n";
            $param_hash->{epoch}      = $date->epoch;
            $param_hash->{quote}      = $entry->[1] if ($entry->[1]);
            $param_hash->{underlying} = $entry->[2] if (scalar @$entry == 3);
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
        }

    }

    subtest($testname, $test);
}

done_testing;

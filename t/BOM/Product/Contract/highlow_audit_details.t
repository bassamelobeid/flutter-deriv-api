#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use File::Slurp;
use Data::Dumper;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $json = JSON::MaybeXS->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });
my $one_day = Date::Utility->new('2014-07-10 10:00:00');

for (0 .. 1) {
    my $epoch = $one_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick highlow' => sub {

    my $now_tickhilo = Date::Utility->new('10-Mar-2015');

    my $args_tickhilo = {
        bet_type      => 'TICKHIGH',
        underlying    => 'R_100',
        selected_tick => 5,
        date_start    => $now_tickhilo,
        date_pricing  => $now_tickhilo,
        duration      => '5t',
        currency      => 'USD',
        payout        => 10,
    };

    my $quote = 100.000;
    for my $i (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
            epoch      => $now_tickhilo->epoch + $i,
        });
        $quote += 0.01;
    }

    lives_ok {
        $args_tickhilo->{date_pricing} = $now_tickhilo->plus_time_interval('5s');
        my $c = produce_contract($args_tickhilo);
        #    ok !$c->hit_tick, 'first tick is next tick';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now_tickhilo->epoch + 5,
            quote      => 100.1,
        });

        $c = produce_contract({%$args_tickhilo, selected_tick => 5});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"tick":"100","tick_display_value":"100.00","epoch":1425945600,"flag":"highlight_time","name":["Start Time"]},{"tick":"100.01","tick_display_value":"100.01","epoch":1425945601,"flag":"highlight_tick","name":["Entry Spot"]},{"tick":"100.02","tick_display_value":"100.02","epoch":1425945602},{"epoch":1425945603,"tick":"100.03","tick_display_value":"100.03"},{"tick":"100.04","tick_display_value":"100.04","epoch":1425945604},{"name":["[_1] and [_2]",["[_1] and [_2]","End Time","Exit Spot"],"Highest Spot"],"flag":"highlight_tick","epoch":1425945605,"tick":"100.1","tick_display_value":"100.10"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that last tick is the winning tick - selected tick , 5';

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 4});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, '0 payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"name":["Start Time"],"epoch":1425945600,"tick":"100","tick_display_value":"100.00","flag":"highlight_time"},{"name":["Entry Spot"],"tick":"100.01","tick_display_value":"100.01","epoch":1425945601,"flag":"highlight_tick"},{"epoch":1425945602,"tick":"100.02","tick_display_value":"100.02"},{"tick":"100.03","tick_display_value":"100.03","epoch":1425945603},{"epoch":1425945604,"tick":"100.04","tick_display_value":"100.04"},{"flag":"highlight_tick","epoch":1425945605,"tick":"100.1","tick_display_value":"100.10","name":["[_1] and [_2]",["[_1] and [_2]","End Time","Exit Spot"],"Highest Spot"]}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that last tick is the winning tick - selected tick, 4';

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 3});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, '0 payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"epoch":1425945600,"name":["Start Time"],"tick":"100","tick_display_value":"100.00","flag":"highlight_time"},{"tick":"100.01","tick_display_value":"100.01","flag":"highlight_tick","epoch":1425945601,"name":["Entry Spot"]},{"epoch":1425945602,"tick":"100.02","tick_display_value":"100.02"},{"tick":"100.03","tick_display_value":"100.03","epoch":1425945603},{"name":["[_1] and [_2]","End Time","Exit Spot"],"epoch":1425945604,"flag":"highlight_tick","tick":"100.04","tick_display_value":"100.04"},{"tick":"100.1","tick_display_value":"100.10","flag":"highlight_tick","epoch":1425945605,"name":["Highest Spot"]}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that last tick is the winning tick - selected tick, 3';

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 2});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, '0 payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"name":["Start Time"],"epoch":1425945600,"flag":"highlight_time","tick":"100","tick_display_value":"100.00"},{"tick":"100.01","tick_display_value":"100.01","flag":"highlight_tick","epoch":1425945601,"name":["Entry Spot"]},{"tick":"100.02","tick_display_value":"100.02","epoch":1425945602},{"tick":"100.03","tick_display_value":"100.03","flag":"highlight_tick","epoch":1425945603,"name":["[_1] and [_2]","End Time","Exit Spot"]},{"epoch":1425945604,"tick":"100.04","tick_display_value":"100.04"},{"name":["Highest Spot"],"epoch":1425945605,"flag":"highlight_tick","tick":"100.1","tick_display_value":"100.10"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that last tick is the winning tick - selected tick, 2';

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 1});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, '0 payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"tick":"100","tick_display_value":"100.00","flag":"highlight_time","epoch":1425945600,"name":["Start Time"]},{"epoch":1425945601,"name":["Entry Spot"],"tick":"100.01","tick_display_value":"100.01","flag":"highlight_tick"},{"flag":"highlight_tick","tick":"100.02","tick_display_value":"100.02","name":["[_1] and [_2]","End Time","Exit Spot"],"epoch":1425945602},{"tick":"100.03","tick_display_value":"100.03","epoch":1425945603},{"epoch":1425945604,"tick":"100.04","tick_display_value":"100.04"},{"epoch":1425945605,"name":["Highest Spot"],"tick":"100.1","tick_display_value":"100.10","flag":"highlight_tick"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that last tick is the winning tick - selected tick, 1 ';

#Add winning case below
    lives_ok {
        $args_tickhilo->{bet_type} = 'TICKLOW';
        my $c = produce_contract({%$args_tickhilo, selected_tick => 1});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"tick":"100","tick_display_value":"100.00","epoch":1425945600,"name":["Start Time"],"flag":"highlight_time"},{"name":["[_1] and [_2]",["Entry Spot"],"Lowest Spot"],"epoch":1425945601,"tick":"100.01","tick_display_value":"100.01","flag":"highlight_tick"},{"epoch":1425945602,"tick":"100.02","tick_display_value":"100.02"},{"epoch":1425945603,"tick":"100.03","tick_display_value":"100.03"},{"epoch":1425945604,"tick":"100.04","tick_display_value":"100.04"},{"flag":"highlight_tick","tick":"100.1","tick_display_value":"100.10","epoch":1425945605,"name":["[_1] and [_2]","End Time","Exit Spot"]}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that first tick is the winning tick - selected tick, 1 ';

    $now_tickhilo = Date::Utility->new('11-Mar-2015');

    $args_tickhilo = {
        bet_type      => 'TICKLOW',
        underlying    => 'R_100',
        selected_tick => 2,
        date_start    => $now_tickhilo,
        date_pricing  => $now_tickhilo->plus_time_interval('5s'),
        duration      => '5t',
        currency      => 'USD',
        payout        => 10,
    };

    $quote = 100.000;
    #0..4
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 1,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote - 0.01,
        epoch      => $now_tickhilo->epoch + 2,
    });
    $quote = 100.000;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 3,
    });
    $quote = $quote + 0.01;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 4,
    });
    $quote = $quote + 0.01;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 5,
    });

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 2});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"epoch":1425945605,"tick":"100.1","tick_display_value":"100.10"},{"flag":"highlight_time","tick":"100","tick_display_value":"100.00","epoch":1426032000,"name":["Start Time"]},{"flag":"highlight_tick","name":["Entry Spot"],"epoch":1426032001,"tick":"100","tick_display_value":"100.00"},{"flag":"highlight_tick","tick":"99.99","tick_display_value":"99.99","epoch":1426032002,"name":["Lowest Spot"]},{"epoch":1426032003,"tick":"100","tick_display_value":"100.00"},{"tick":"100.01","tick_display_value":"100.01","epoch":1426032004},{"epoch":1426032005,"name":["[_1] and [_2]","End Time","Exit Spot"],"tick":"100.02","tick_display_value":"100.02","flag":"highlight_tick"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that first tick is the winning tick - selected tick, 2';

    $now_tickhilo = Date::Utility->new('12-Mar-2015');

    $args_tickhilo = {
        bet_type      => 'TICKLOW',
        underlying    => 'R_100',
        selected_tick => 3,
        date_start    => $now_tickhilo,
        date_pricing  => $now_tickhilo->plus_time_interval('5s'),
        duration      => '5t',
        currency      => 'USD',
        payout        => 10,
    };

    $quote = 100.000;
    #0..4
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 1,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 2,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote - 0.01,
        epoch      => $now_tickhilo->epoch + 3,
    });
    $quote = 100.000;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 4,
    });
    $quote = $quote + 0.01;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 5,
    });

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 3});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"epoch":1426032005,"tick":"100.02","tick_display_value":"100.02"},{"tick":"100","tick_display_value":"100.00","epoch":1426118400,"flag":"highlight_time","name":["Start Time"]},{"name":["Entry Spot"],"flag":"highlight_tick","tick":"100","tick_display_value":"100.00","epoch":1426118401},{"epoch":1426118402,"tick":"100","tick_display_value":"100.00"},{"epoch":1426118403,"tick":"99.99","tick_display_value":"99.99","flag":"highlight_tick","name":["Lowest Spot"]},{"tick":"100","tick_display_value":"100.00","epoch":1426118404},{"name":["[_1] and [_2]","End Time","Exit Spot"],"flag":"highlight_tick","epoch":1426118405,"tick":"100.01","tick_display_value":"100.01"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that first tick is the winning tick - selected tick, 3';

    $now_tickhilo = Date::Utility->new('13-Mar-2015');

    $args_tickhilo = {
        bet_type      => 'TICKLOW',
        underlying    => 'R_100',
        selected_tick => 4,
        date_start    => $now_tickhilo,
        date_pricing  => $now_tickhilo->plus_time_interval('5s'),
        duration      => '5t',
        currency      => 'USD',
        payout        => 10,
    };

    $quote = 100.000;
    #0..4
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 1,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 2,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 3,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote - 0.01,
        epoch      => $now_tickhilo->epoch + 4,
    });
    $quote = 100.000;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 5,
    });

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 4});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"tick":"100.01","tick_display_value":"100.01","epoch":1426118405},{"name":["Start Time"],"tick":"100","tick_display_value":"100.00","epoch":1426204800,"flag":"highlight_time"},{"epoch":1426204801,"tick":"100","tick_display_value":"100.00","name":["Entry Spot"],"flag":"highlight_tick"},{"tick":"100","tick_display_value":"100.00","epoch":1426204802},{"epoch":1426204803,"tick":"100","tick_display_value":"100.00"},{"flag":"highlight_tick","name":["Lowest Spot"],"tick":"99.99","tick_display_value":"99.99","epoch":1426204804},{"tick":"100","tick_display_value":"100.00","epoch":1426204805,"name":["[_1] and [_2]","End Time","Exit Spot"],"flag":"highlight_tick"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that first tick is the winning tick - selected tick, 4';

    $now_tickhilo = Date::Utility->new('14-Mar-2015');

    $args_tickhilo = {
        bet_type      => 'TICKLOW',
        underlying    => 'R_100',
        selected_tick => 5,
        date_start    => $now_tickhilo,
        date_pricing  => $now_tickhilo->plus_time_interval('5s'),
        duration      => '5t',
        currency      => 'USD',
        payout        => 10,
    };

    $quote = 100.000;
    #0..4
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 1,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 2,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 3,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote,
        epoch      => $now_tickhilo->epoch + 4,
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        quote      => $quote - 0.01,
        epoch      => $now_tickhilo->epoch + 5,
    });

    lives_ok {
        my $c = produce_contract({%$args_tickhilo, selected_tick => 5});
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        my $expected = $json->decode(
            '{"all_ticks":[{"epoch":1426204805,"tick":"100","tick_display_value":"100.00"},{"flag":"highlight_time","epoch":1426291200,"name":["Start Time"],"tick":"100","tick_display_value":"100.00"},{"tick":"100","tick_display_value":"100.00","epoch":1426291201,"flag":"highlight_tick","name":["Entry Spot"]},{"epoch":1426291202,"tick":"100","tick_display_value":"100.00"},{"epoch":1426291203,"tick":"100","tick_display_value":"100.00"},{"tick":"100","tick_display_value":"100.00","epoch":1426291204},{"epoch":1426291205,"flag":"highlight_tick","name":["[_1] and [_2]",["[_1] and [_2]","End Time","Exit Spot"],"Lowest Spot"],"tick":"99.99","tick_display_value":"99.99"}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'check that first tick is the winning tick - selected tick, 5';
};


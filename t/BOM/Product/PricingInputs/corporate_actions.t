#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 7);
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Quant::Framework::CorporateAction;
use Quant::Framework::Utils::Test;

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'index',
    {
        symbol => 'FPFP',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => 'FPFP',
        recorded_date => Date::Utility->new,
    });

my $date       = Date::Utility->new('2013-03-27');
my $opening    = BOM::Market::Underlying->new('FPFP')->exchange->opening_on($date);
my $underlying = BOM::Market::Underlying->new('FPFP');
my $starting   = $underlying->exchange->opening_on(Date::Utility->new('2013-03-27'))->plus_time_interval('50m');
my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch,
    quote      => 100
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 90,
    quote      => 80
});

subtest 'invalid operation' => sub {
    plan tests => 3;
    my $invalid_action = {
        11223344 => {
            description    => 'Action with invalid modifier',
            flag           => 'N',
            modifier       => 'garbage',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
        }};

    Quant::Framework::Utils::Test::create_doc('corporate_action',
        {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            actions => $invalid_action
        });

    lives_ok {
        my $date_pricing = $starting->plus_time_interval('1d');
        my $bet_params   = {
            underlying   => $underlying,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting,
            duration     => '1d',
            barrier      => 'S0P',
            entry_tick   => $entry_tick,
            date_pricing => $date_pricing,
        };
        my $bet = produce_contract($bet_params);
        ok $bet->barrier->as_absolute, 'barrier built successfully';
        like $bet->primary_validation_error->message, qr/Could not apply corporate action/, 'error is added';
    }
    'invalid operation added during object initialization';
};

subtest 'valid action during bet pricing' => sub {
    plan tests => 6;
    my $effective_date = $opening->plus_time_interval('1d');
    my $invalid_action = {
        11223344 => {
            description    => 'Action with \'delete\' modifier',
            flag           => 'U',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $effective_date->date_ddmmmyy,
            type           => 'DVD_STOCK',
        }};

    Quant::Framework::Utils::Test::create_doc('corporate_action',
        {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            actions => $invalid_action
        });

    lives_ok {
        my $date_pricing = $starting->plus_time_interval('1d');
        my $bet_params   = {
            underlying   => $underlying,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting,
            duration     => '1d',
            barrier      => 'S0P',
            entry_tick   => $entry_tick,
            date_pricing => $starting,
        };
        my $bet = produce_contract($bet_params);
        cmp_ok($bet->date_pricing->epoch, "<", $effective_date->epoch, 'corporate action\'s effective date is after date_pricing');
        ok !@{$bet->corporate_actions}, 'bet is not effected by corporate actions if date_pricing is before effective date of corporate action';
        $bet_params->{date_pricing} = $date_pricing;
        my $new_bet = produce_contract($bet_params);
        cmp_ok($new_bet->date_pricing->epoch, ">", $effective_date->epoch, 'corporate action\'s effective date is after date_pricing');
        isa_ok($new_bet->corporate_actions, 'ARRAY');
        is(scalar @{$new_bet->corporate_actions}, 1, 'one action found');
    }
};

subtest 'intraday bet' => sub {
    my $effective_date = $opening;
    lives_ok {
        my $invalid_action = {
            11223344 => {
                description    => 'Action with modifier',
                flag           => 'U',
                modifier       => 'divide',
                value          => 1.25,
                effective_date => $effective_date->date_ddmmmyy,
                type           => 'DVD_STOCK',
            }};
        my $bet_params = {
            underlying => $underlying,
            bet_type   => 'CALL',
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '3h',
            barrier    => 'S0P',
            entry_tick => $entry_tick,
        };
        my $bet = produce_contract($bet_params);
        ok !@{$bet->corporate_actions}, 'no corporate action for intraday bet';
    }
    'corporate actions on intraday bet';
};

subtest 'one action' => sub {
    plan tests => 13;

    my $one_action = {
        11223344 => {
            description    => 'Test corp act 1',
            flag           => 'U',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
        }};

    Quant::Framework::Utils::Test::create_doc('corporate_action',
        {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            actions => $one_action,
        });


    lives_ok {
        my $closing_time = $starting->plus_time_interval('1d')->truncate_to_day->plus_time_interval('23h59m59s');
        my $bet_params   = {
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting,
            duration     => '1d',
            barrier      => 'S0P',
            entry_tick   => $entry_tick,
            date_pricing => $closing_time,
        };
        my $bet = produce_contract($bet_params);
        ok @{$bet->corporate_actions}, 'bet is affected by corporate action';
        cmp_ok $bet->barrier->as_absolute, '==', 80.00, 'original quote adjusted by corporate action';
        my $expiry = $bet->date_expiry->truncate_to_day;
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            underlying => 'FPFP',
            epoch      => $expiry->epoch,
            close      => 79,
            high       => 79
        });
        is $bet->is_expired, 1, 'bet expired';
        is $bet->value,      0, 'zero payout because barrier is adjusted';
    }
    'one action on single barrier daily expiry bet';

    my $date_pricing = $starting->plus_time_interval('1d');
    lives_ok {
        my $bet_params = {
            underlying   => $underlying,
            bet_type     => 'ONETOUCH',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting,
            duration     => '7d',
            barrier      => 99,
            entry_tick   => $entry_tick,
            date_pricing => $date_pricing,
        };
        my $bet = produce_contract($bet_params);
        ok @{$bet->corporate_actions}, 'bet is affected by corporate action';
        cmp_ok $bet->barrier->as_absolute, '==', 79.20, 'original quote adjusted by corporate action';
        is $bet->is_expired, 0, 'bet does not expire when dividend stock takes place';
        is $bet->value,      0, 'zero payout because barrier is adjusted';
    }
    'one action on single barrier path dependent bet';

    lives_ok {
        my $bet_params = {
            underlying   => $underlying,
            bet_type     => 'EXPIRYRANGE',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting->plus_time_interval('5m1s'),
            duration     => '7d',
            high_barrier => 102,
            low_barrier  => 98,
            entry_tick   => $entry_tick,
            date_pricing => $date_pricing,
        };
        my $bet = produce_contract($bet_params);
        cmp_ok $bet->high_barrier->as_absolute, '==', 81.60, 'upper barrier adjusted by corporate action';
        cmp_ok $bet->low_barrier->as_absolute,  '==', 78.40, 'lower barrier adjusted by corporate action';
    }
    'one action on double barrier bet';
};

subtest 'two actions' => sub {
    plan tests => 5;

    my $two_actions = {
        11223344 => {
            description    => 'Test corp act 1',
            flag           => 'N',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
            action_code    => '2002'
        },
        11223355 => {
            description    => 'Test corp act 2',
            flag           => 'N',
            modifier       => 'divide',
            value          => 1.45,
            effective_date => $opening->plus_time_interval('2d')->date_ddmmmyy,
            type           => 'DVD_STOCK',
            action_code    => '2000'
        },
    };

    Quant::Framework::Utils::Test::create_doc('corporate_action',
        {
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            actions => $two_actions
        });

    my $date_pricing = $starting->plus_time_interval('2d');
    lives_ok {
        my $bet_params = {
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting,
            duration     => '3d',
            barrier      => 'S0P',
            entry_tick   => $entry_tick,
            date_pricing => $date_pricing,
        };
        my $bet = produce_contract($bet_params);
        cmp_ok $bet->barrier->as_absolute, '==', 55.17, 'original quote adjusted by corporate action';
    }
    'two actions on single barrier bet';

    lives_ok {
        my $bet_params = {
            underlying   => $underlying,
            bet_type     => 'EXPIRYRANGE',
            currency     => 'USD',
            payout       => 100,
            date_start   => $starting->plus_time_interval('5m1s'),
            duration     => '7d',
            high_barrier => 102,
            low_barrier  => 98,
            entry_tick   => $entry_tick,
            date_pricing => $date_pricing,
        };
        my $bet = produce_contract($bet_params);
        cmp_ok $bet->high_barrier->as_absolute, '==', 56.28, 'upper barrier adjusted by corporate action';
        cmp_ok $bet->low_barrier->as_absolute,  '==', 54.07, 'lower barrier adjusted by corporate action';
    }
    'two actions on double barrier bet';
};

subtest 'order check' => sub {
    plan tests => 10;

    my $id_1 = 11223344;
    my $id_2 = 11223355;

    my %corp_args = (
        $id_1 => {
            description    => 'Test corp act 1',
            flag           => 'N',
            modifier       => 'divide',
            value          => 1.25,
            effective_date => $opening->plus_time_interval('1h')->date_ddmmmyy,
            type           => 'DVD_STOCK',
            action_code    => '2002'
        },
        $id_2 => {
            description    => 'Test corp act 2',
            flag           => 'N',
            modifier       => 'divide',
            value          => 1.45,
            effective_date => $opening->plus_time_interval('1h1m')->date_ddmmmyy,
            type           => 'DVD_STOCK',
            action_code    => '2000'
        });

    lives_ok {
        my $two_actions = \%corp_args;


        Quant::Framework::Utils::Test::create_doc('corporate_action',
            {
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
                actions => $two_actions,
                symbol  => 'USPM'
            });
        $underlying = BOM::Market::Underlying->new('USPM');
        throws_ok { $underlying->corporate_actions } qr/Could not determine order of corporate actions/,
            'throws exception if we have two corporate actions with action_code before';
    }
    'two firsts';

    lives_ok {
        $corp_args{$id_1}->{action_code} = 2001;
        $corp_args{$id_2}->{action_code} = 2003;
        my $two_actions = \%corp_args;

        Quant::Framework::Utils::Test::create_doc('corporate_action',
            {
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
                actions => $two_actions,
                symbol  => 'USPM'
            });

        $underlying = BOM::Market::Underlying->new('USPM');
        throws_ok { $underlying->corporate_actions } qr/Could not determine order of corporate actions/,
            'throws exception if we have two corporate actions with action_code after';
    }
    'two lasts';

    lives_ok {
        my %new = (
            44553311 => {
                description    => 'Test corp act 1',
                flag           => 'N',
                modifier       => 'divide',
                value          => 1.25,
                effective_date => $opening->plus_time_interval('1h')->date_ddmmmyy,
                type           => 'DVD_CASH',
            });

        $corp_args{$id_1}->{type}        = 'STOCK_SPLT';
        $corp_args{$id_1}->{flag}        = 'U';
        $corp_args{$id_1}->{action_code} = 3001;

        $corp_args{$id_2}->{action_code} = 2000;
        my $actions = {%corp_args, %new};

        Quant::Framework::Utils::Test::create_doc('corporate_action',
            {
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
                actions => $actions,
                symbol  => 'USPM'
            });

        $underlying = BOM::Market::Underlying->new('USPM');
        my $ordered_act;
        lives_ok { $ordered_act = $underlying->corporate_actions } 're-arranged actions';
        is ref $ordered_act, 'ARRAY', 'is an array ref';
        is $ordered_act->[0]->{type}, 'DVD_STOCK',  'first DVD_STOCK';
        is $ordered_act->[1]->{type}, 'DVD_CASH',   'mid DVD_CASH';
        is $ordered_act->[2]->{type}, 'STOCK_SPLT', 'last STOCK_SPLT';

    }
    'proper order';
};

use strict;
use warnings;

=head1 NAME

timeindays.t

=head1 DESCRIPTION

Tests the timeindays method of BOM::Product::Contract.

=cut

use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Config::Chronicle;
use Quant::Framework;

my $FRW_frxUSDJPY_ON = create_underlying('FRW_frxUSDJPY_ON');
my $FRW_frxUSDJPY_TN = create_underlying('FRW_frxUSDJPY_TN');
my $FRW_frxUSDJPY_1W = create_underlying('FRW_frxUSDJPY_1W');
my $FRW_frxUSDJPY_1M = create_underlying('FRW_frxUSDJPY_1M');
my $FRW_frxUSDJPY_2M = create_underlying('FRW_frxUSDJPY_2M');
my $FRW_frxUSDJPY_3M = create_underlying('FRW_frxUSDJPY_3M');
my $FRW_frxUSDJPY_6M = create_underlying('FRW_frxUSDJPY_6M');
my $FRW_frxUSDJPY_1Y = create_underlying('FRW_frxUSDJPY_1Y');

my $fake_data = {
    epoch => Date::Utility->new('2012-01-11 10:00:00')->epoch,
    quote => 1,
};

{
    #we can have warnigns here because symbol name is invalid
    local $SIG{__WARN__} = sub { };
    $FRW_frxUSDJPY_ON->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_TN->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_1W->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_1M->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_2M->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_3M->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_6M->set_combined_realtime($fake_data);
    $FRW_frxUSDJPY_1Y->set_combined_realtime($fake_data);
}

TODO: subtest Forex => sub {
    local $TODO = 'Intermittent failures on Perl 5.26 (very small differences)';

    plan tests => 14;

    Test::Exception::lives_ok {
        my $date = Date::Utility->new('2012-01-11 10:00:00');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => '99.840'
        });
    }

    # normal one day bet
    my $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-01-11 10:00:00'),
        date_expiry => Date::Utility->new('12-Jan-12')->plus_time_interval('23h59m59s'),
    );

    is(
        $bet->timeindays->amount,
        ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400,
        'Wed -> Thurs FX bet (expiry: 23:59, rollover: 22:00).'
    );
    cmp_ok(
        $bet->vol_at_strike,
        '==',
        $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        ),
        'We select correct vol.'
    );

    # bet expiring on Friday
    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-01-11 10:00:00'),
        date_expiry => Date::Utility->new('13-Jan-12')->plus_time_interval('21h'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'Wed -> Fri FX bet (expiry: 21:00, rollover: 22:00).');
    cmp_ok(
        $bet->vol_at_strike,
        '==',
        $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        ),
        'We select correct vol.'
    );

    # bets in summer time:
    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-04-04 10:00:00'),
        date_expiry => Date::Utility->new('5-Apr-12')->plus_time_interval('23h59m59s'),
    );
    is(
        $bet->timeindays->amount,
        ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400,
        'Wed -> Thurs FX bet in summer (expiry: 23:59, rollover: 21:00).'
    );
    cmp_ok(
        $bet->vol_at_strike,
        '==',
        $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        ),
        'We select correct vol.'
    );

    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-04-04 10:00:00'),
        date_expiry => Date::Utility->new('6-Apr-12')->plus_time_interval('23h59m59s'),
    );
    is(
        $bet->timeindays->amount,
        ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400,
        'Wed -> Fri FX bet in summer (expiry: 21:00, rollover: 21:00).'
    );
    cmp_ok(
        $bet->vol_at_strike,
        '==',
        $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        ),
        'We select correct vol.'
    );

    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-09 10:00:00'),
        date_expiry => Date::Utility->new('29-Mar-12')->plus_time_interval('23h59m59s'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'Three week FX bet in summer.');
    ok(
        abs($bet->vol_at_strike - $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        )) < 0.0001,
        'We select correct vol.'
    );

    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-09 10:00:00'),
        date_expiry => Date::Utility->new('30-Mar-12')->plus_time_interval('23h59m59s'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'Three week FX bet in summer ending on Friday.');
    ok(
        abs($bet->vol_at_strike - $bet->volsurface->get_volatility({
                from   => $bet->effective_start,
                to     => $bet->date_expiry,
                spot   => 100,
                strike => $bet->barrier->as_absolute,
                r_rate => $bet->r_rate,
                q_rate => $bet->q_rate,
            },
        )) < 0.0001,
        'We select correct vol.'
    );

    # intraday bet?
    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-09 10:00:00'),
        date_expiry => Date::Utility->new('2012-03-09 11:00:00'),
    );
    cmp_ok(
        $bet->timeindays->amount,
        '==',
        ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400,
        'Intraday bet: does not follow integer days convnetion.'
    );
};

subtest 'Forex date start after cutoff' => sub {

    note('Daylight Savings (DST) for 2012 is from March 11th to November 4th.');
    note('DST rollover time 21:00GMT, non DST 22:00GMT');

    my $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-12 21:00:01'),
        date_expiry => Date::Utility->new('2012-03-16 21:00:00'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'timeindays is 4 days after rollover in DST.');
    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-12 20:59:59'),
        date_expiry => Date::Utility->new('2012-03-16 21:00:00'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'timeindays is 5 days before rollover in DST.');

    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-05 22:00:01'),
        date_expiry => Date::Utility->new('2012-03-09 21:00:00'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'timeindays is 4 days after rollover in non DST.');
    $bet = _sample_bet(
        date_start  => Date::Utility->new('2012-03-05 21:59:59'),
        date_expiry => Date::Utility->new('2012-03-09 21:00:00'),
    );
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->date_start->epoch) / 86400, 'timeindays is 5 days before rollover in non DST.');
};

subtest Equity => sub {
    plan tests => 1;

    # normal one day bet
    my $underlying       = create_underlying('FCHI');
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $bet              = _sample_bet(
        underlying  => $underlying,
        date_start  => Date::Utility->new('2012-01-11 10:30:00'),
        date_expiry => $trading_calendar->closing_on($underlying->exchange, Date::Utility->new('18-Jan-12')),
    );
    cmp_ok($bet->timeindays->amount, '==', 7.25, 'One week EQ bet: does not follow integer days concept.');
};

sub _sample_bet {
    my %overrides = @_;

    my $symbol = $overrides{underlying} || 'frxUSDJPY';
    my $underlying = (ref $symbol eq 'Quant::Framework::Underlying') ? $symbol : create_underlying($symbol);

    $overrides{date_pricing} ||= $overrides{date_start};

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $overrides{date_pricing},
        }) for (qw/GBP JPY USD JPY-USD/);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol => 'JPY',
            rates  => {
                1   => 0.2,
                2   => 0.15,
                7   => 0.18,
                32  => 0.25,
                62  => 0.2,
                92  => 0.18,
                186 => 0.1,
                365 => 0.13,
            },
            recorded_date => $overrides{date_pricing},
            type          => 'implied',
            implied_from  => 'USD'
        });

    $underlying->set_combined_realtime({
        epoch => $overrides{date_pricing}->epoch,
        quote => 99.840
    });

    my $current_tick = Postgres::FeedDB::Spot::Tick->new({
        underlying => $underlying,
        epoch      => $overrides{date_pricing}->epoch,
        quote      => 100,
    });

    my $start_epoch = Date::Utility->new($overrides{date_start})->epoch;
    my %bet_args    = ((
            underlying   => $underlying,
            bet_type     => 'CALL',
            payout       => 100,
            currency     => 'USD',
            barrier      => 100,
            current_tick => $current_tick,
        ),
        %overrides,
    );

    # Let's add a vol surface to DB so that the bet can be priced.
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_' . $underlying->volatility_surface_type,
        {
            underlying    => $underlying,
            recorded_date => $overrides{date_pricing},
            surface       => _sample_surface_data(),
        });

    return produce_contract(\%bet_args);
}

sub _sample_surface_data {
    return {
        ON => {
            smile => {
                25 => 0.12,
                50 => 0.13,
                75 => 0.12,
            },
            vol_spread => {50 => 0.01},
        },
        7 => {
            smile => {
                25 => 0.12,
                50 => 0.11,
                75 => 0.14,
            },
            vol_spread => {50 => 0.01},
        },
        14 => {
            smile => {
                25 => 0.13,
                50 => 0.12,
                75 => 0.15,
            },
            vol_spread => {50 => 0.01},
        },
        30 => {
            smile => {
                25 => 0.14,
                50 => 0.13,
                75 => 0.16,
            },
            vol_spread => {50 => 0.01},
        },
        60 => {
            smile => {
                25 => 0.15,
                50 => 0.14,
                75 => 0.17,
            },
            vol_spread => {50 => 0.01},
        },
        91 => {
            smile => {
                25 => 0.16,
                50 => 0.15,
                75 => 0.18,
            },
            vol_spread => {50 => 0.01},
        },
        182 => {
            smile => {
                25 => 0.17,
                50 => 0.16,
                75 => 0.19,
            },
            vol_spread => {50 => 0.01},
        },
    };
}

subtest 'timeindays for non-ATM volatility indices' => sub {
    my $date_start_even = Date::Utility->new('2017-12-21');
    my $args            = {
        bet_type   => 'CALL',
        underlying => 'frxUSDJPY',
        barrier    => 'S10P',
        date_start => $date_start_even,
        duration   => '1m',
        currency   => 'USD',
        payout     => 100,
    };
    my $c = produce_contract($args);
    is $c->timeindays->amount, 60 / 86400, 'no adjustment made to forex';
    $args->{underlying} = 'R_100';
    $args->{duration}   = '5m';
    $c                  = produce_contract($args);
    is $c->timeindays->amount, 5 * 60 / 86400, 'no adjustment made to volatility indices if duration is 5m';
    $args->{duration} = '15s';
    $c = produce_contract($args);
    is $c->timeindays->amount, 12 / 86400, 'date start adjusted by 2 seconds and date expiry adjusted by 1 second';
    $args->{duration} = '16s';
    $c = produce_contract($args);
    is $c->timeindays->amount, 14 / 86400, 'date start adjusted 2 seconds';
    $args->{date_start} = $date_start_even->epoch + 1;
    $args->{duration}   = '15s';
    $c                  = produce_contract($args);
    is $c->timeindays->amount, 14 / 86400, 'date start adjusted by 1 second';
    $args->{barrier} = 'S0P';
    $c = produce_contract($args);
    is $c->timeindays->amount, 15 / 86400, 'no adjustment for ATM contract on volatility indices';
    $args->{barrier}  = 'S10P';
    $args->{for_sale} = 1;
    $c                = produce_contract($args);
    is $c->timeindays->amount, 15 / 86400, 'no adjustment for_sale on volatility indices';

    $args->{for_sale}   = 0;
    $args->{date_start} = $date_start_even;
    $args->{duration}   = '5t';
    $c                  = produce_contract($args);
    is $c->timeindays->amount, 10 / 86400, '10 seconds in duration for a 5 tick contract that starts on an even second';
    $args->{date_start} = $date_start_even->epoch + 1;
    $c = produce_contract($args);
    is $c->timeindays->amount, 10 / 86400, '10 seconds in duration for a 5 tick contract that starts on an odd second';
};

done_testing;

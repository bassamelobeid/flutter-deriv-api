package BOM::Market::GBM;

=pod

=head1 NAME

BOM::Market::GBM

=head1 DESCRIPTION

Handles Geometrics Brownian Motion calculations

=cut

use strict;
use warnings;
use feature "state";

use Carp qw( confess );
use List::MoreUtils qw( all );
use List::Util qw( max );
use Math::Random::Normal::Leva qw( gbm_sample );
use Path::Tiny;
use Time::HiRes qw(time);

use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::Market::UnderlyingDB;
use BOM::Market::SubMarket::Registry;
use BOM::System::Config;
use Date::Utility;
use Path::Tiny;

use base qw( Exporter );
our @EXPORT_OK = qw( random_index_gbm get_randoms_ref );

=head2 random_index_gbm

GBM calculation wrapper specifically for our generating our Random markets.

Changes in place a reference of:

{
    spot            => $current_spot,
    underlying      => $underlying,
    int_rate        => $int_rate,
    div_rate        => $div_rate,
    generation_time => $spot_generation_epoch,
    reset_time      => $next_time_to_reset || undef,
}

Will add/replace keys of spot_used, vol_used, tiy_used with the spot/strike, volatility and
time in years used to create the indicated spot at the generated time.

=cut

sub random_index_gbm {
    my ($info_ref, $when) = @_;

    $when //= time;

    my $underlying = $info_ref->{underlying};

    if ($info_ref->{reset_time} and $when >= $info_ref->{reset_time}) {
        $info_ref->{spot} = _reset_value($underlying);
        $info_ref->{reset_time} = _next_reset($underlying, $when);
    } else {
        my $interval =
            ($when - $info_ref->{generation_time}) / (365 * 24 * 60 * 60);
        my $spot_for_strike = $info_ref->{spot};
        my $volsurface      = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
        my $vol             = $volsurface->get_volatility({
            strike    => $spot_for_strike,
            days      => $interval * 365,
            for_epoch => $when,
        });
        my $crand;
        $crand = \&crand if BOM::System::Config::env ne 'development';
        $info_ref->{spot}      = gbm_sample($info_ref->{spot}, $vol, $interval, $info_ref->{int_rate}, $info_ref->{div_rate}, $crand);
        $info_ref->{vol_used}  = $vol;
        $info_ref->{tiy_used}  = $interval;
        $info_ref->{spot_used} = $spot_for_strike;
    }

    return $info_ref->{generation_time} = $when;
}

sub crand {
    my $rand = _redis()->rpop('Feed::Rand');
    if (not defined $rand) {
        $rand = Math::Random::Secure::rand();
        Path::Tiny::path('/feed/rand/used_' . Date::Utility->today->date_yyyymmdd)->append("$rand l\n");
    } else {
        Path::Tiny::path('/feed/rand/used_' . Date::Utility->today->date_yyyymmdd)->append("$rand\n");
    }

    return $rand;
}

sub _redis {
    state $redis_read = RedisDB->new(
        host     => BOM::System::Config::randsrv()->{rand_server}->{fqdn},
        port     => BOM::System::Config::randsrv()->{rand_server}->{port},
        password => BOM::System::Config::randsrv()->{rand_server}->{password},
    );
    return $redis_read;
}

=head2 get_randoms_ref

Get a hashref for all our current randoms with each sub_ref
suitable for use in random_index_gbm

=cut

sub get_randoms_ref {
    my %GBM_vars;
    my @available_random_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'volidx',
        contract_category => 'ANY'
    );

    foreach my $ticker (@available_random_symbols) {

        my $underlying = BOM::Market::Underlying->new($ticker);
        my $T          = $underlying->market->generation_interval->days / 365;
        my $tick_info  = _latest_tick_info($underlying);
        my $int_rate   = $underlying->interest_rate_for($T);
        my $div_rate   = $underlying->dividend_rate_for($T);

        $GBM_vars{$ticker} = {
            underlying      => $underlying,
            int_rate        => $int_rate,
            div_rate        => $div_rate,
            spot            => $tick_info->{spot},
            generation_time => $tick_info->{generation_time},
            reset_time      => _next_reset($underlying, $tick_info->{generation_time}),
        };
    }

    return \%GBM_vars;
}

sub _next_reset {
    my ($underlying, $epoch) = @_;

    my $when = Date::Utility->new(int $epoch);

    # Reset at the next open.
    return ($underlying->submarket->resets_at_open)
        ? $underlying->calendar->opening_on($underlying->trade_date_after($when))->epoch
        : undef;
}

#
# Get the latest tick and its timestamp for an underlying
sub _latest_tick_info {
    my ($underlying) = @_;

    my $date = Date::Utility->today;
    my $i    = 0;
    while (not -e $underlying->fullfeed_file($date->date_ddmmmyy, 'random')
        and $i++ < 30)
    {
        $date = $date->minus_time_interval('1d');
    }
    my $when;
    my $spot;
    if ($i == 30) {
        $when = time - 2;
        $spot = _reset_value($underlying);
    } else {
        my $file = $underlying->fullfeed_file($date->date_ddmmmyy, 'random');
        my @lines = path($file)->lines;
        my ($epoch, undef, undef, undef, $price) = split /,/, $lines[-1];
        $when = $epoch;
        $spot = $price;
    }

    # We never want to bridge a gap of more than 1 hour.
    # When it doesn't exist, pretend it was 2 seconds ago.
    $when = max(time - 3600, $when);

    die $0 . ': Cannot find latest quote for ' . $underlying->symbol
        if not $spot;
    die $0 . ': Quote for ' . $underlying->symbol . ', ' . $spot . ' is less than 0.1'
        if $spot < 0.1;

    return {
        spot            => $spot,
        generation_time => $when
    };
}

sub _reset_value {
    my $underlying = shift;

    my $reset_value;    # By default no reset value.

    if ($underlying->submarket->resets_at_open) {
        if ($underlying->volatility_surface_type eq 'moneyness') {

            # Make sure the surface aligns with reset value.
            $reset_value = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying})->spot_reference;
        } else {
            $reset_value = 1000;    # Default for resets on other (esp. Flat) surfaces
        }
    }

    return $reset_value;
}

1;

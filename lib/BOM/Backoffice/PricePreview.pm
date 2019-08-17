package BOM::Backoffice::PricePreview;

use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);

use Try::Tiny;
use Format::Util::Numbers qw(roundcommon);
use LandingCompany::Registry;
use Volatility::EconomicEvents;
use Quant::Framework;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::VolSurface::Delta;
use Date::Utility;
use Finance::Exchange;
use Math::Business::BlackScholesMerton::NonBinaries;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new;

sub generate_form {
    my $url = shift;

    my $input = update_price_preview({symbol => 'USD'});
    return BOM::Backoffice::Request::template()->process(
        'backoffice/price_preview_form.html.tt',
        +{
            upload_url => $url,
            headers    => $json->encode($input->{headers}),
            prices     => $json->encode($input->{prices}),
        },
    ) || die BOM::Backoffice::Request::template()->error;
}

sub update_price_preview {
    my $args = shift;

    my $prices = try {
        calculate_prices($args)
    }
    catch {
        +{error => 'Exception thrown while calculating prices: ' . $_};
    };

    return $prices if $prices->{error};
    return {} unless %$prices;
    # just take one as sample.
    my $first_symbol = (keys %$prices)[0];
    my @headers = map { $_->[0] } sort { $a->[1]->epoch <=> $b->[1]->epoch } map { [$_, Date::Utility->new($_)] } keys %{$prices->{$first_symbol}};

    return {
        headers => \@headers,
        prices  => $prices,
    };
}

sub calculate_prices {
    my $args = shift;

    $args->{symbol}        ||= 'USD';
    $args->{expiry_option} ||= 'end_of_day';
    $args->{pricing_date} =~ s/\s+//g if $args->{pricing_date};
    # default to svg since it does not matter
    my $offerings_obj = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my @underlying_symbols =
          $args->{symbol} eq 'ALL'
        ? $offerings_obj->query({submarket => ['major_pairs', 'minor_pairs']}, ['underlying_symbol'])
        : grep { $_ =~ /$args->{symbol}/ } $offerings_obj->query({submarket => ['major_pairs', 'minor_pairs']}, ['underlying_symbol']);

    my $cr = BOM::Config::Chronicle::get_chronicle_reader();
    my $cw = BOM::Config::Chronicle::get_chronicle_writer();
    # if we are calculating volatility for a modified event, adjust it here.
    if (my $event = $args->{event}) {
        my $ul = delete $event->{underlying};

        $event->{custom}->{$ul} =
            {map { my $v = delete $event->{$_}; $v ne '' ? ($_ => $_ =~ /vol/ ? $v / 100 : $_ =~ /duration/ ? $v * 60 : $v) : () }
                qw/vol_change duration vol_change_before duration_before decay_factor decay_factor_before/};

        die 'Please specify at least one change' unless %{$event->{custom}};

        my $eec = Quant::Framework::EconomicEventCalendar->new(
            chronicle_reader => $cr,
            chronicle_writer => $cw
        );
        $eec->update_event($event, 0);    # don't save event since it is for preview only

        Volatility::EconomicEvents::set_prefix(time);
        Volatility::EconomicEvents::generate_variance({
            underlying_symbols => \@underlying_symbols,
            economic_events    => $eec->existing_events(),
            chronicle_writer   => $cw,
        });
    }

    my $calendar     = Quant::Framework->trading_calendar($cr);
    my $now          = Date::Utility->new();
    my $pricing_from = $args->{pricing_date} ? Date::Utility->new($args->{pricing_date})->truncate_to_day : Date::Utility->new->truncate_to_day;

    die 'Price preview only support forward pricing' if $now->truncate_to_day->epoch > $pricing_from->epoch;

    my $exchange = Finance::Exchange->create_exchange('FOREX');
    # We take the New York 10 volatility surface cutoff from Bloomberg
    my $offset = $pricing_from->is_dst_in_zone('America/New_York') ? '14h' : '15h';

    my @expiries;
    foreach my $day (1 .. 7) {
        my $d      = $pricing_from->plus_time_interval($day . 'd');
        my $expiry = '-';

        if ($calendar->trades_on($exchange, $d)) {
            if ($args->{expiry_option} eq 'new_york_10') {
                $expiry = $d->truncate_to_day->plus_time_interval($offset);
            } else {
                $expiry = $calendar->closing_on($exchange, $d);
            }
        }

        push @expiries,
            +{
            date  => $d->date,
            close => $expiry
            };
    }

    my $preview_output = {};
    foreach my $symbol (@underlying_symbols) {
        my $underlying = create_underlying($symbol);
        my $volsurface = Quant::Framework::VolSurface::Delta->new({
            underlying       => $underlying,
            chronicle_reader => $cr,
        });
        my $current_spot = $underlying->spot_tick->quote;
        foreach my $expiry (@expiries) {
            if (ref $expiry->{close} ne 'Date::Utility') {
                $preview_output->{$symbol}{$expiry->{date}}{vol}       = '-';
                $preview_output->{$symbol}{$expiry->{date}}{mid_price} = '-';
            } else {
                my $vol = $volsurface->get_volatility({
                    strike => $current_spot,
                    from   => $now->epoch,
                    to     => $expiry->{close}->epoch,
                });

                my $tiy = ($expiry->{close}->epoch - $now->epoch) / (365 * 86400);
                my $v_call = Math::Business::BlackScholesMerton::NonBinaries::vanilla_call($current_spot, $current_spot, $tiy, 0, 0, $vol);
                my $v_put = Math::Business::BlackScholesMerton::NonBinaries::vanilla_put($current_spot, $current_spot, $tiy, 0, 0, $vol);
                $preview_output->{$symbol}{$expiry->{close}->datetime}{vol} = roundcommon(0.0001, $vol);
                $preview_output->{$symbol}{$expiry->{close}->datetime}{mid_price} = roundcommon(0.0001, ($v_call + $v_put) / 2);
            }
        }
    }

    # reset prefix
    Volatility::EconomicEvents::set_prefix('');

    return $preview_output;
}

1;

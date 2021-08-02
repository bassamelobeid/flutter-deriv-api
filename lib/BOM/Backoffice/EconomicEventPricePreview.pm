package BOM::Backoffice::EconomicEventPricePreview;

use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);
use Syntax::Keyword::Try;
use Format::Util::Numbers qw(roundcommon);
use LandingCompany::Registry;
use Volatility::EconomicEvents;
use Quant::Framework;
use Quant::Framework::EconomicEventCalendar;
use Date::Utility;
use Finance::Exchange;
use Math::Business::BlackScholesMerton::NonBinaries;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Backoffice::EconomicEventTool;
use LandingCompany::Registry;
use Storable qw(dclone);
use Log::Any qw($log);

#News generation

sub generate_news {

    my $args = shift // 0;

    my $news = {};

    if ($args) {

        $news->{$args->{date}}->{$args->{underlying_symbol}} =
            event_retriever($args->{date}, $args->{underlying_symbol});

        return $news;
    }

    my $underlying_symbol_list;

    my $landing_company = LandingCompany::Registry::get('virtual');

    $underlying_symbol_list = [
        $landing_company->basic_offerings({
                loaded_revision => 1,
                action          => 1
            }
        )->query({submarket => 'major_pairs'}, ['underlying_symbol'])];

    #Working days for next two weeks
    my $day_diff_matrix = [];

    my $day_adjustment = [0 .. 5, -1];

    for my $weekday (0 .. 6) {

        $day_diff_matrix->[$weekday] = [grep { $_ >= 0 } map { $_ - $day_adjustment->[$weekday] } 1 .. 5, 8 .. 12];

    }

    ##Extraction of economic events for working days of next two weeks.

    my $weekday_today = Date::Utility->new()->day_of_week;

    foreach my $day_diff (@{$day_diff_matrix->[$weekday_today]}) {

        my $date = Date::Utility->new()->truncate_to_day->plus_time_interval($day_diff . 'd')->date;

        foreach my $underlying (@$underlying_symbol_list) {
            $news->{$date}->{$underlying} =
                event_retriever($date, $underlying);
        }

    }

    return ($news, $underlying_symbol_list);
}

#generation of dashboard information
sub generate_economic_event_form {
    my $url = shift;

    #update underlying symbol list
    my ($weekly_news, $underlying_symbol_list) = generate_news();

    my $input = update_economic_event_price_preview();
    return BOM::Backoffice::Request::template()->process(
        'backoffice/economic_event_price_preview_form.html.tt',
        +{
            upload_url        => $url,
            headers           => encode_json_utf8($input->{headers}       // {}),
            prices            => encode_json_utf8($input->{prices}        // {}),
            news_info         => encode_json_utf8($input->{news_info}     // {}),
            underlying_symbol => encode_json_utf8($underlying_symbol_list // {}),
            weekly_news       => encode_json_utf8($weekly_news            // {}),

        },
    ) || die BOM::Backoffice::Request::template()->error;
}

sub update_economic_event_price_preview {
    my $args = shift;
    my $prices;
    my $news_info;
    try {
        ($prices, $news_info) = calculate_economic_event_prices($args)
    } catch ($e) {
        $prices = {error => 'Exception thrown while calculating prices: ' . $e};
        $log->warn($prices->{error});
    }

    return $prices if $prices->{error};
    return {} unless %$prices;

    # just take one as sample.
    my $first_start_time = (keys %$prices)[0];

    my @headers =
        map  { $_->[0] }
        sort { $a->[1]->epoch <=> $b->[1]->epoch }
        map  { [$_, Date::Utility->new($_)] }
        keys %{$prices->{$first_start_time}};

    return {
        headers   => \@headers,
        prices    => $prices,
        news_info => $news_info,
    };
}

#computation of volatilities and straddle prices
sub calculate_economic_event_prices {
    my $args = shift;

    $args->{date}                   ||= Date::Utility->new()->date;
    $args->{underlying_symbol}      ||= 'frxEURUSD';
    $args->{event_timeframe}        ||= 'incoming_event';
    $args->{event_type}             ||= 'significant_event';
    $args->{event_parameter_change} ||= 0;

    my $daily_news = generate_news($args);

    #default news event when initialization
    my $filtered_news = $daily_news->{$args->{date}}->{$args->{underlying_symbol}}->{$args->{event_timeframe}}->{$args->{event_type}};

    if (not defined $filtered_news) {
        return;
    }

    $filtered_news = [sort { $filtered_news->{$a}->{release_date} <=> $filtered_news->{$b}->{release_date} } keys %$filtered_news];

    $args->{event_name} ||= $filtered_news->[0];

    my $event =
        dclone($daily_news->{$args->{date}}->{$args->{underlying_symbol}}->{$args->{event_timeframe}}->{$args->{event_type}}->{$args->{event_name}});

    #When there is customized change of parameter
    if ($args->{event_parameter_change}) {

        my $parameter_list = [qw/vol_change duration vol_change_before duration_before decay_factor decay_factor_before/];

        foreach my $parameter (@$parameter_list) {

            if (my $value = $args->{event_parameter_change}->{$parameter}) {

                die "duration should be less than 1000" if (($parameter =~ /duration/) and ($value > 1000));

                $event->{custom}->{$args->{underlying_symbol}}->{$parameter} =
                    ($parameter =~ /duration/) ? $value * 60 : ($parameter =~ /vol_change/) ? $value / 100 : $value;
                $event->{$parameter} = $value;
            }
        }
    }

    #Contracts during economic event
    my $contract_range;
    my $start_time = [-5, 0, 1,  5,  10];
    my $end_time   = [1,  5, 10, 15, 20, 30, 60];

    foreach my $start (@$start_time) {
        foreach my $end (@$end_time) {

            push @$contract_range,
                {
                'start_time' => Date::Utility->new($event->{release_date} + $start * 60),
                'end_time'   => Date::Utility->new($event->{release_date} + $end * 60)};

        }
    }

    ##clear cache
    Volatility::LinearCache::clear_cache();

    my $output = {};

    my $delta_object = Quant::Framework::VolSurface::Delta->new(
        underlying       => create_underlying($args->{underlying_symbol}),
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        custom_event     => $event
    );

    $event->{current_spot} =
        create_underlying($args->{underlying_symbol})->spot_tick->quote;

    foreach my $range (@$contract_range) {
        if ($range->{start_time}->epoch >= $range->{end_time}->epoch) {
            $output->{$range->{start_time}->datetime}{$range->{end_time}->datetime}{vol}       = '-';
            $output->{$range->{start_time}->datetime}{$range->{end_time}->datetime}{mid_price} = '-';
        } else {

            my $vol = $delta_object->get_volatility({
                strike => $event->{current_spot},
                from   => $range->{start_time}->epoch,
                to     => $range->{end_time}->epoch,
            });

            my $tiy    = ($range->{end_time}->epoch - $range->{start_time}->epoch) / (365 * 86400);
            my $v_call = Math::Business::BlackScholesMerton::NonBinaries::vanilla_call(1, 1, $tiy, 0, 0, $vol);
            my $v_put  = Math::Business::BlackScholesMerton::NonBinaries::vanilla_put(1, 1, $tiy, 0, 0, $vol);
            $output->{$range->{start_time}->datetime}{$range->{end_time}->datetime}{vol}       = roundcommon(0.00001, $vol);
            $output->{$range->{start_time}->datetime}{$range->{end_time}->datetime}{mid_price} = roundcommon(0.00001, ($v_call + $v_put) / 2);
        }
    }

    #Useful information to be filled

    $event->{release_date} =
        Date::Utility->new($event->{release_date})->datetime;
    $event->{underlying_symbol} = $args->{underlying_symbol};

    return ($output, $event);

}

#Extraction of economic event for specific date and underlying symbol
sub event_retriever {

    my ($date, $underlying_symbol) = @_;

    my $start_of_day = Date::Utility->new($date)->truncate_to_day;
    my $end_of_day   = $start_of_day->plus_time_interval('23h59m59s');

    my $retriever = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
    );

    my $raw_events = $retriever->get_latest_events_for_period({
        from => $start_of_day,
        to   => $end_of_day,
    });

    #getting the default parameter of economic events
    $raw_events =
        [map { BOM::Backoffice::EconomicEventTool::get_info($_) } @$raw_events];

    foreach my $new (@$raw_events) {
        $new->{release_date} =
            Date::Utility->new($new->{release_date})->epoch;
    }

    my $incoming_event = {};
    my $ongoing_event  = {};
    my $past_event     = {};

    #fill in the event information
    my $info_filler = sub {

        my ($event_ind, $output, $input, $significance) = @_;

        if ($significance) {

            foreach my $parameter_name (keys %{$input->{info}->{$underlying_symbol}}) {

                my $parameter = $input->{info}->{$underlying_symbol}->{$parameter_name};

                $parameter += 0;
                $input->{info}->{$underlying_symbol}->{$parameter_name} =
                    (($parameter_name =~ /vol/) ? $parameter * 100 : ($parameter_name =~ /duration/) ? $parameter / 60 : $parameter);
            }

            $output->{significant_event}->{$event_ind} = {
                symbol     => $input->{symbol},
                event_name => $input->{event_name},
                %{$input->{info}->{$underlying_symbol}},
                (defined $input->{custom} ? (custom => $input->{custom}) : ())};

        } else {

            $output->{insignificant_event}->{$event_ind} = {
                symbol       => $input->{symbol},
                event_name   => $input->{event_name},
                release_date => $input->{release_date}};
            $output->{insignificant_event}->{$event_ind}->{$_} = '-'
                foreach qw(vol_change duration decay_factor vol_change_before duration_before decay_factor_before);

        }

    };

    my $time_now = Date::Utility->new();
    foreach my $new (@$raw_events) {

        my $event_ind = $new->{symbol} . ' - ' . $new->{event_name};
        if (defined($new->{info}->{$underlying_symbol})) {

            if ($new->{release_date} > $time_now->epoch) {
                $info_filler->($event_ind, $incoming_event, $new, 1);
            } elsif (($new->{release_date} + ($new->{info}->{$underlying_symbol}->{duration}) * 60) > $time_now->epoch) {
                $info_filler->($event_ind, $ongoing_event, $new, 1);
            } else {
                $info_filler->($event_ind, $past_event, $new, 1);
            }
        } else {

            if ($new->{release_date} > $time_now->epoch) {
                $info_filler->($event_ind, $incoming_event, $new, 0);
            } else {
                $info_filler->($event_ind, $past_event, $new, 0);
            }
        }
    }

    my $result = {};
    $result->{'incoming_event'} = $incoming_event;
    $result->{'ongoing_event'}  = $ongoing_event;
    $result->{'past_event'}     = $past_event;

    return $result;
}

1;

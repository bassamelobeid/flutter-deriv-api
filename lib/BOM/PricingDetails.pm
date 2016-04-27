package BOM::PricingDetails;

=head1 NAME

BOM::PricingDetails

=head1 DESCRIPTION

A Moose object which provides a Price Debug in html.

=cut

use 5.010;
use Moose;
use namespace::autoclean;
use POSIX qw( floor );
use namespace::autoclean;
use List::MoreUtils qw(uniq);
use Try::Tiny;

use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::Market::Underlying;
use Date::Utility;
use Format::Util::Numbers qw( roundnear );
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use VolSurface::Utils qw( get_delta_for_strike get_strike_for_spot_delta get_1vol_butterfly);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
use BOM::Greeks::FiniteDifference;

use BOM::MarketData::Display::VolatilitySurface;
use BOM::DisplayGreeks;
use Try::Tiny;

=head1 ATTRIBUTES

=cut

has bet => (
    is       => 'ro',
    isa      => 'BOM::Product::Contract',
    required => 1,
);

has number_format => (
    is      => 'ro',
    isa     => 'Str',
    default => '%.2f',
);

has _volsurface_mapper => (
    is         => 'ro',
    isa        => 'BOM::MarketData::Fetcher::VolSurface',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build__volsurface_mapper {
    return BOM::MarketData::Fetcher::VolSurface->new;
}

has master_surface => (
    is         => 'rw',
    isa        => 'BOM::MarketData::VolSurface',
    lazy_build => 1,
);

sub _build_master_surface {
    my $self = shift;

    my $constructor_args = {underlying => $self->bet->underlying};
    $constructor_args->{for_date} = $self->bet->date_pricing
        if (not $self->bet->pricing_new);

    my $master_surface = $self->_volsurface_mapper->fetch_surface($constructor_args);

    return $master_surface;
}

sub debug_link {
    my ($self) = @_;

    my $bet           = $self->bet;
    my $number_format = $self->number_format;

    my $attr_content   = $self->_get_overview();
    my $greeks_content = $self->_get_greeks();

    my $ask_price_content = $self->_get_price({
        id   => 'buildask' . $bet->id,
        prob => $bet->ask_probability,
    });

    my $bid_price_content = $self->_get_price({
        id   => 'buildbid' . $bet->id,
        prob => $bet->bid_probability,
    });

    my $tabs_content = [{
            label   => 'Overview',
            url     => 'ov',
            content => $attr_content,
        },
        {
            label   => 'Ask Price',
            url     => 'askpb',
            content => $ask_price_content,
        },
        {
            label   => 'Bid Price',
            url     => 'bidpb',
            content => $bid_price_content,
        },
        {
            label   => 'Greeks',
            url     => 'gr',
            content => $greeks_content,
        },
    ];

    my $volsurface = try {
        ($self->bet->underlying->volatility_surface_type eq 'moneyness')
            ? $self->_get_moneyness_surface()
            : $self->_get_volsurface();
    }
    catch { 'Surface display error.' };
    push @{$tabs_content},
        {
        label   => 'Vol Surface',
        url     => 'vols',
        content => $volsurface,
        };

    my $dvol = $self->_get_dvol();
    push @{$tabs_content},
        {
        label   => 'DVol',
        url     => 'dv',
        content => $dvol,
        };

    # rates
    if (grep { $bet->underlying->market->name eq $_ } ('forex', 'commodities', 'indices')) {
        push @{$tabs_content},
            {
            label   => 'Rates',
            url     => 'rq',
            content => $self->_get_rates()};
    }

    my $debug_link;
    BOM::Platform::Context::template->process(
        'backoffice/container/debug_link.html.tt',
        {
            bet_id => $bet->id,
            tabs   => $tabs_content
        },
        \$debug_link
    ) || die BOM::Platform::Context::template->error;

    return $debug_link;
}

sub _get_rates {
    my $self          = shift;
    my $bet           = $self->bet;
    my $underlying    = $bet->underlying;
    my $number_format = '%.3f';
    my $spot          = $underlying->spot;

    my $headers;
    if (grep { $underlying->market->name eq $_ } ('forex', 'commodities')) {
        $headers = [
            ['',       '',     $underlying->asset_symbol, $underlying->quoted_currency_symbol, $underlying->symbol],
            ['Expiry', 'Date', 'Deposit',                 'Deposit',                           'Forward']];
    } else {
        $headers = [['', '', '', '', $underlying->symbol], ['Expiry', 'Date', 'Dividend', 'Interest', 'Forward']];
    }

    my $rows;
    my @days = @{$bet->volsurface->original_term_for_smile};
    foreach my $day (@days) {
        my $tiy                = $day / 365;
        my $r                  = sprintf($number_format, $underlying->interest_rate_for($tiy) * 100);
        my $q                  = sprintf($number_format, $underlying->dividend_rate_for($tiy) * 100);
        my $forward_spot_price = $underlying->pipsized_value($spot * exp(($r / 100 - $q / 100) * $tiy));

        if ($day != int($day)) {
            $day = sprintf('%.5f', $day);
        }
        my $date = Date::Utility->new({epoch => (Date::Utility->new->epoch + int($day) * 86400)})->date;
        push @{$rows}, [$day, $date, $q, $r, $forward_spot_price];
    }

    my $rates_content;
    BOM::Platform::Context::template->process(
        'backoffice/container/full_table_from_arrayrefs.html.tt',
        {
            headers => $headers,
            rows    => $rows,
        },
        \$rates_content
    ) || die BOM::Platform::Context::template->error;

    return $rates_content;
}

sub _get_dvol {
    my $self = shift;
    my $bet  = $self->bet;

    my $surfaces = {master => $self->master_surface};
    if (
        $bet->underlying->market->name eq 'forex'
        or (    $bet->underlying->market->name eq 'commodities'
            and $bet->underlying->symbol ne 'frxBROUSD'))
    {
        $surfaces->{used} = $bet->volsurface;
    }

    my $spot = $bet->underlying->spot;
    my $days = {
        0.000694444444444 => '1Min',
        0.041666666667    => '1H',
        1                 => '1D',
        7                 => '1W',
        30                => '1M',
        60                => '2M',
        90                => '3M',
        180               => '6M',
        270               => '9M',
        365               => '1Y',
    };
    my @deltas = qw(95 90 85 80 75 70 50 30 25 20 15 10 5);
    my @days_display =
        (map { $days->{$_} } (sort { $a <=> $b } keys %{$days}));

    my $tabs;
    foreach my $key (keys %{$surfaces}) {
        my $surface = $surfaces->{$key};
        my $vols_table;
        foreach my $day (sort { $a <=> $b } keys %{$days}) {
            my $args;
            $args->{spot}   = $spot;
            $args->{t}      = $day / 365;
            $args->{r_rate} = $bet->underlying->interest_rate_for($args->{t});
            $args->{q_rate} = $bet->underlying->dividend_rate_for($args->{t});
            $args->{premium_adjusted} =
                $bet->underlying->{market_convention}->{delta_premium_adjusted};
            $args->{atm_vol} = $surface->get_volatility({
                delta => 50,
                days  => $day
            });
            DELTA:

            foreach my $delta (@deltas) {
                $args->{delta}       = $delta / 100;
                $args->{option_type} = 'VANILLA_CALL';
                if ($args->{delta} > 0.5) {
                    $args->{delta} =
                        exp(-$args->{r_rate} * $args->{t}) - $args->{delta};
                    $args->{option_type} = 'VANILLA_PUT';
                }
                my ($strike, $vol);
                try {
                    $strike = get_strike_for_spot_delta($args);
                    $vol    = $surface->get_volatility({
                        delta => $delta,
                        days  => $day
                    });
                    if ($vol and $strike) {
                        $vols_table->{$days->{$day}}->{$delta} = {
                            vol    => sprintf('%.3f', $vol * 100),
                            strike => sprintf('%.3f', $strike),
                        };
                    }
                }
            }
        }

        my ($url, $label);
        if ($key eq 'master') {
            $url   = 'dvm';
            $label = 'Master DVol';
        } elsif ($key eq 'used') {
            $url   = 'dvu';
            $label = 'Used DVol';
        }

        push @{$tabs},
            {
            url        => $url,
            vols_table => $vols_table,
            cut        => $surface->cutoff->code,
            label      => $self->_get_cutoff_label($surface->cutoff),
            };
    }

    my $vol_content;
    BOM::Platform::Context::template->process(
        'backoffice/price_debug/dvol_tab.html.tt',
        {
            bet_id => $bet->id,
            deltas => [@deltas],
            days   => [@days_display],
            tabs   => $tabs,
        },
        \$vol_content
    ) || die BOM::Platform::Context::template->error;

    return $vol_content;
}

sub _get_cutoff_label {
    my ($self, $cutoff) = @_;

    $cutoff->code =~ /^(.+) (\d{1,2}:\d{2})/;
    my $city = $1;
    my $time = $2;
    my %map  = (
        'New York' => 'NY',
        'Tokyo'    => 'TK',
    );
    my $code;
    if ($city eq 'UTC') {
        $code = 'GMT ' . $time;
    } else {
        $code = ((defined $map{$city}) ? $map{$city} : $city) . ' ' . $time;
        $code .= ' (' . $cutoff->code_gmt . ')';
    }
    return $code;
}

sub _get_moneyness_surface {
    my $self = shift;

    my $dates = [];
    my $bet   = $self->bet;
    try {
        $dates = $bet->volsurface->fetch_historical_surface_date({back_to => 20});
    }
    catch {
        warn("caught error in _get_moneyness_surface: $_");
    };

    my @unique_dates   = uniq(@$dates);
    my $master_vol_url = 'mv';

    my $master_display = BOM::MarketData::Display::VolatilitySurface->new(surface => $self->master_surface);
    my $master_surface_content = $master_display->rmg_table_format({
        historical_dates => \@unique_dates,
        tab_id           => $bet->id . $master_vol_url,
    });

    return $master_surface_content;
}

sub _get_volsurface {
    my $self = shift;
    my $bet  = $self->bet;

    # There's a small chance that we'll get a timeout here.
    # If we do, just carry on; we don't need to show these dates.
    my $dates = [];
    try {
        $dates = $bet->volsurface->fetch_historical_surface_date({back_to => 20})
    };

    my $tabs;

    # VolSurface for Tokyo 15 Cutoff
    if ($bet->underlying->market->name eq 'forex') {
        my $tokyo_vol_url = 'tv';

        my $constructor_args = {
            underlying => $bet->underlying,
            cutoff     => 'Tokyo 15:00',
        };
        $constructor_args->{for_date} = $bet->date_pricing
            if (not $bet->pricing_new);

        my $tokyo_surface = $self->_volsurface_mapper->fetch_surface($constructor_args);

        my $tokyo_display = BOM::MarketData::Display::VolatilitySurface->new(surface => $tokyo_surface);
        my $tokyo_surface_content = $tokyo_display->rmg_table_format({
            historical_dates => $dates,
            tab_id           => $bet->id . $tokyo_vol_url,
        });

        push @{$tabs},
            {
            label   => $self->_get_cutoff_label($tokyo_surface->cutoff),
            url     => $tokyo_vol_url,
            content => $tokyo_surface_content,
            };
    }

    # master vol surface
    my $master_vol_url         = 'mv';
    my $master_display         = BOM::MarketData::Display::VolatilitySurface->new(surface => $self->master_surface);
    my $master_surface_content = $master_display->rmg_table_format({
        historical_dates => $dates,
        tab_id           => $bet->id . $master_vol_url,
    });
    push @{$tabs},
        {
        label   => $self->_get_cutoff_label($self->master_surface->cutoff),
        url     => $master_vol_url,
        content => $master_surface_content,
        };

    # Used vol surface: display for forex & commodities (exclude Oil/USD)
    if (
        $bet->underlying->market->name eq 'forex'
        or (    $bet->underlying->market->name eq 'commodities'
            and $bet->underlying->symbol ne 'frxBROUSD'))
    {
        my $cost_greeks        = $self->_get_cost_of_greeks();
        my $used_vol_url       = 'vs';
        my $display            = BOM::MarketData::Display::VolatilitySurface->new(surface => $bet->volsurface);
        my $volsurface_content = $display->rmg_table_format({
            greeks           => $cost_greeks,
            historical_dates => $dates,
            tab_id           => $bet->id . $used_vol_url,
        });

        push @{$tabs},
            {
            label   => $self->_get_cutoff_label($bet->volsurface->cutoff),
            url     => $used_vol_url,
            content => $volsurface_content,
            };
    }

    my $vol_content;
    BOM::Platform::Context::template->process(
        'backoffice/price_debug/vol_tab.html.tt',
        {
            bet_id => $bet->id,
            tabs   => $tabs,
        },
        \$vol_content
    ) || die BOM::Platform::Context::template->error;

    return $vol_content;
}

sub _get_price {
    my ($self, $args) = @_;
    my $id          = $args->{id};
    my $probability = $args->{prob};

    my $price_content;
    BOM::Platform::Context::template->process(
        'backoffice/container/tree_builder.html.tt',
        {
            id      => $id,
            content => $self->_debug_prob(['reset', $probability])
        },
        \$price_content
    ) || die BOM::Platform::Context::template->error;

    return $price_content;
}

sub _get_greeks {
    my $self          = shift;
    my $number_format = '%.3f';
    my $bet           = $self->bet;

    my $fd_greeks = BOM::Greeks::FiniteDifference->new({bet => $bet});
    my $bs_greeks = $bet->greek_engine->get_greeks;

    my $display_greeks_engine = BOM::DisplayGreeks->new(
        payout         => $bet->payout,
        priced_with    => $bet->priced_with,
        pricing_greeks => $fd_greeks->get_greeks,
        current_spot   => $bet->current_spot,
        underlying     => $bet->underlying
    );
    my $display = $display_greeks_engine->get_display_greeks();
    my $diff;

    foreach my $greek (qw(delta gamma theta vega vanna volga)) {
        $diff->{$greek} = (
            not $bs_greeks->{$greek}
                or (abs($bs_greeks->{$greek} - $fd_greeks->{$greek})) / abs($bs_greeks->{$greek}) * 100 > 2
        ) ? 'red' : 'normal';
    }

    my $base_curr    = $bet->underlying->asset_symbol;
    my $num_curr     = $bet->underlying->quoted_currency_symbol;
    my $greeks_attrs = [{
            label             => 'Delta',
            analytical        => sprintf($number_format, $bs_greeks->{delta}),
            finite_difference => sprintf($number_format, $fd_greeks->{delta}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{delta}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{delta}->{num}),
            color             => $diff->{delta},
        },
        {
            label             => 'Gamma',
            analytical        => sprintf($number_format, $bs_greeks->{gamma}),
            finite_difference => sprintf($number_format, $fd_greeks->{gamma}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{gamma}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{gamma}->{num}),
            color             => $diff->{gamma},
        },
        {
            label             => 'Theta',
            analytical        => sprintf($number_format, $bs_greeks->{theta}),
            finite_difference => sprintf($number_format, $fd_greeks->{theta}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{theta}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{theta}->{num}),
            color             => $diff->{theta},
        },
        {
            label             => 'Vega',
            analytical        => sprintf($number_format, $bs_greeks->{vega}),
            finite_difference => sprintf($number_format, $fd_greeks->{vega}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{vega}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{vega}->{num}),
            color             => $diff->{vega},
        },
        {
            label             => 'Vanna',
            analytical        => sprintf($number_format, $bs_greeks->{vanna}),
            finite_difference => sprintf($number_format, $fd_greeks->{vanna}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{vanna}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{vanna}->{num}),
            color             => $diff->{vanna},
        },
        {
            label             => 'Volga',
            analytical        => sprintf($number_format, $bs_greeks->{volga}),
            finite_difference => sprintf($number_format, $fd_greeks->{volga}),
            display_base      => $base_curr . " " . sprintf($number_format, $display->{volga}->{base}),
            display_num       => $num_curr . " " . sprintf($number_format, $display->{volga}->{num}),
            color             => $diff->{volga},
        },
    ];

    my $payout        = $bet->payout;
    my $is_quanto     = $bet->priced_with;
    my $greeks_header = ['Greek Name', 'Analytical Greek (1 unit)', 'FD Greek (1 unit)', "Greek * $payout $base_curr", "Greek * $payout $num_curr"];
    my $greeks_content;
    BOM::Platform::Context::template->process(
        'backoffice/container/four_column_table.html.tt',
        {
            title     => 'Bet Display Greeks',
            rows      => $greeks_attrs,
            headers   => $greeks_header,
            is_quanto => $is_quanto,
        },
        \$greeks_content
    ) || die BOM::Platform::Context::template->error;

    return $greeks_content;
}

sub _get_overview {
    my $self          = shift;
    my $number_format = $self->number_format;
    my $bet           = $self->bet;

    my @pricing_attrs = ({
            label => 'Black-Scholes price',
            value => $bet->currency . ' ' . $bet->bs_price
        },
        {
            label => 'Corrected theo price',
            value => $bet->currency . ' ' . $bet->theo_price
        },
        {
            label => 'Ask price',
            value => $bet->currency . ' ' . $bet->ask_price
        },
        {
            label => 'Bid price',
            value => $bet->currency . ' ' . $bet->bid_price
        },
    );

    my $barrier_to_compare = ($bet->two_barriers) ? $bet->high_barrier : $bet->barrier;

    my @pricing_param = ({
            label => 'Duration in days (number of vol rollovers between start and end)',
            value => sprintf('%.5g', $bet->timeindays->amount),
        },
        {
            label => 'Vol at Strike',
            value => sprintf($number_format, $bet->vol_at_strike * 100) . '%'
        },
        {
            label => 'Pricing IV (for this model)',
            value => sprintf($number_format, $bet->pricing_args->{iv} * 100) . '%'
        },
        {
            label => 'Use discrete dividend',
            value => ($bet->underlying->market->prefer_discrete_dividend)
            ? 'yes'
            : 'no',
        },
        {
            label => 'Dividend rate (of base)',
            value => sprintf($number_format, $bet->q_rate * 100) . '%',
        },
        {
            label => 'Interest rate (of numeraire)',
            value => sprintf($number_format, $bet->r_rate * 100) . '%',
        },
        {
            label => 'Quanto rate (of payout currency)',
            value => sprintf($number_format, $bet->discount_rate * 100) . '%',
        },
        {
            label => 'Spot',
            value => $bet->current_spot,
        },
        {
            label => 'Spot adjustment',
            value => roundnear(0.0001, $bet->pricing_spot - $bet->current_spot),
        },
        {
            label => 'Barrier adjustment',
            value => roundnear(0.0001, $bet->_barriers_for_pricing->{barrier1} - $barrier_to_compare->as_absolute),
        },
    );

    # Delta for Strike
    my $atm_vol = $bet->volsurface->get_volatility({
        delta => 50,
        days  => $bet->timeinyears->amount * 365,
    });
    my ($delta_strike1, $delta_strike2);
    if ($bet->two_barriers) {
        $delta_strike1 = 100 * get_delta_for_strike({
            strike           => $bet->high_barrier->as_absolute,
            atm_vol          => $atm_vol,
            t                => $bet->timeinyears->amount,
            spot             => $bet->current_spot,
            r_rate           => $bet->r_rate,
            q_rate           => $bet->q_rate,
            premium_adjusted => $bet->underlying->{market_convention}->{delta_premium_adjusted},
        });
        $delta_strike2 = 100 * get_delta_for_strike({
            strike           => $bet->low_barrier->as_absolute,
            atm_vol          => $atm_vol,
            t                => $bet->timeinyears->amount,
            spot             => $bet->current_spot,
            r_rate           => $bet->r_rate,
            q_rate           => $bet->q_rate,
            premium_adjusted => $bet->underlying->{market_convention}->{delta_premium_adjusted},
        });
    } else {
        $delta_strike1 = 100 * get_delta_for_strike({
            strike           => $bet->barrier->as_absolute,
            atm_vol          => $atm_vol,
            t                => $bet->timeinyears->amount,
            spot             => $bet->current_spot,
            r_rate           => $bet->r_rate,
            q_rate           => $bet->q_rate,
            premium_adjusted => $bet->underlying->{market_convention}->{delta_premium_adjusted},
        });
    }

    # survival prob
    my $survival_prob;
    if ($bet->pricing_engine_name eq 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated') {
        $survival_prob = 100 * $bet->pricing_engine_name->new({bet => $bet})->survival_weight->{'survival_probability'};
    }

    my @bet_character = ({
            label => 'Delta for barrier / high barrier',
            value => sprintf($number_format, $delta_strike1),
        },
        {
            label => 'Delta for lower barrier',
            value => ($delta_strike2) ? sprintf($number_format, $delta_strike2)
            : '',
        },
        {
            label => 'Survival Probability',
            value => ($survival_prob) ? (sprintf('%.2f', $survival_prob) . '%')
            : '',
        },
        {
            label => 'Forward Spot Price',
            value => $bet->underlying->pipsized_value($bet->current_spot * exp(($bet->r_rate - $bet->q_rate) * $bet->timeinyears->amount)),
        },
    );

    my @bet_config = ({
            label => 'Pricing Engine',
            value => $bet->pricing_engine_name,
        },
    );
    foreach my $key (
        sort { $a cmp $b }
        keys %{$bet->underlying->{market_convention}})
    {
        push @bet_config,
            {
            label => $key,
            value => $bet->underlying->{market_convention}->{$key},
            };
    }

    my @tables = ({
            title => 'Pricing',
            rows  => [@pricing_attrs],
        },
        {
            title => 'Pricing Parameters',
            rows  => [@pricing_param],
        },
        {
            title => 'Bet Characteristics',
            rows  => [@bet_character],
        },
        {
            title => 'Configuration',
            rows  => [@bet_config],
        },
    );

    my $overview;
    BOM::Platform::Context::template->process(
        'backoffice/container/multiple_tables.html.tt',
        {
            tables => [@tables],
        },
        \$overview
    ) || die BOM::Platform::Context::template->error;

    return $overview;
}

sub _debug_prob {
    my ($self, $op_prob) = @_;

    my ($operation, $prob_obj) = @{$op_prob};

    my $number_format = '%.5g';

    my %operations_map = (
        add      => '+',
        subtract => '-',
        multiply => '*',
        divide   => '/',
        reset    => '=',
        exp      => 'e^',
        log      => 'ln',
        info     => '#',
        absolute => 'abs',
    );

    # This is just a placeholder until I figure how to actually to do this.
    # It'll be all templatized and what-not.
    my $table             = '<ul>';
    my $range_text        = 'not range-bound';
    my $num_display_class = '';
    if (defined $prob_obj->minimum or defined $prob_obj->maximum) {
        my $min = '-inf';
        my $max = 'inf';
        if (defined $prob_obj->minimum) {
            $min = sprintf($number_format, $prob_obj->minimum);
            $num_display_class = 'price_moved_up'
                if ($prob_obj->amount == $prob_obj->minimum);
        }
        if (defined $prob_obj->maximum) {
            $max = sprintf($number_format, $prob_obj->maximum);
            $num_display_class = 'price_moved_down'
                if ($prob_obj->amount == $prob_obj->maximum);
        }

        $range_text = ' min: ' . $min . ' max: ' . $max;
    }
    my $base_text =
        ($prob_obj->amount != $prob_obj->base_amount)
        ? '= Base: <abbr title="' . $range_text . '">' . sprintf($number_format, $prob_obj->base_amount) . '</abbr>'
        : '';
    my $desc_text = '<abbr title="' . $prob_obj->description . ' (' . $prob_obj->set_by . ')">' . $prob_obj->name . '</abbr>';

    $table .=
          '<li><a>'
        . '<span class="'
        . $num_display_class
        . '"><strong>'
        . $operations_map{$operation}
        . '</strong> '
        . sprintf($number_format, $prob_obj->amount)
        . '</span> '
        . $desc_text . ' '
        . $base_text . '</a>';
    foreach my $sub_prob (@{$prob_obj->adjustments}) {
        $table .= $self->_debug_prob($sub_prob);
    }

    $table .= '</li></ul>';

    return $table;
}

sub _get_cost_of_greeks {
    my $self = shift;
    my $bet  = $self->bet;

    my $cost_greeks;
    if ($bet->pricing_engine_name eq 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated') {
        my $bet_duration   = $bet->date_expiry->days_between(Date::Utility->new);
        my $days_to_expiry = $bet->volsurface->term_by_day;
        foreach my $days (grep { /^\d+$/ } @{$days_to_expiry}) {    # Integer number of days only, now matter what the surface says.
            my $new_bet;
            if ($days == $bet_duration) {
                $new_bet = $bet;
            } else {
                my $date_expiry = Date::Utility->new({epoch => Date::Utility->new->epoch + $days * 86400})->date;
                my %barriers;
                if ($bet->two_barriers) {
                    %barriers = (
                        high_barrier => $bet->high_barrier->supplied_barrier,
                        low_barrier  => $bet->low_barrier->supplied_barrier
                    );
                } else {
                    %barriers = (barrier => $bet->barrier->supplied_barrier);
                }
                $new_bet = produce_contract({
                    'current_spot' => $bet->current_spot,
                    'market'       => $bet->underlying->market,
                    'bet_type'     => $bet->code,
                    'currency'     => $bet->currency,
                    'underlying'   => $bet->underlying,
                    'date_start'   => $bet->date_start,
                    'payout'       => $bet->payout,
                    'date_expiry'  => $date_expiry,
                    %barriers
                });
            }
            my $pe = $new_bet->pricing_engine_name->new({bet => $new_bet});
            my $greeks_market_prices = $pe->greek_market_prices;

            $cost_greeks->{$days} = {
                'vanna' => sprintf('%.5f', $greeks_market_prices->{vanna}),
                'volga' => sprintf('%.5f', $greeks_market_prices->{volga}),
                'vega'  => sprintf('%.5f', $greeks_market_prices->{vega}),
            };
        }
    }
    return $cost_greeks;
}

__PACKAGE__->meta->make_immutable;
1;

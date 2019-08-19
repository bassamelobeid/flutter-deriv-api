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
use List::Util qw(max);
use Try::Tiny;

use BOM::Config::Runtime;
use BOM::Backoffice::Request;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;
use Format::Util::Numbers qw( roundcommon );
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use VolSurface::Utils qw( get_delta_for_strike get_strike_for_spot_delta get_1vol_butterfly);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
use BOM::Config::Chronicle;
use Volatility::EconomicEvents;

use BOM::MarketData::Display::VolatilitySurface;

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
    isa        => 'Quant::Framework::VolSurface',
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

    my $bet = $self->bet;

    my $attr_content = $self->_get_overview();

    my $ask_price_content = $self->_get_price({
        id       => 'buildask' . $bet->id,
        contract => $bet,
        type     => $bet->is_binary ? 'ask_probability' : 'ask_price',
    });

    my $bid_price_content = $self->_get_price({
        id       => 'buildbid' . $bet->id,
        contract => $bet,
        type     => $bet->is_binary ? 'bid_probability' : 'bid_price',
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
    ];

    my $volsurface = try {
        ($self->bet->underlying->volatility_surface_type eq 'moneyness')
            ? $self->_get_moneyness_surface()
            : $self->_get_volsurface();
    }
    catch { 'Surface display error:' . $_ };
    push @{$tabs_content},
        {
        label   => 'Vol Surface',
        url     => 'vols',
        content => $volsurface,
        };

    # rates
    if (grep { $bet->underlying->market->name eq $_ } ('forex', 'commodities', 'indices')) {
        push @{$tabs_content},
            {
            label   => 'Rates',
            url     => 'rq',
            content => $self->_get_rates(),
            };
    }

    my $debug_link;
    BOM::Backoffice::Request::template()->process(
        'backoffice/container/debug_link.html.tt',
        {
            bet_id => $bet->id,
            tabs   => $tabs_content,
        },
        \$debug_link
    ) || die BOM::Backoffice::Request::template()->error;

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
    BOM::Backoffice::Request::template()->process(
        'backoffice/container/full_table_from_arrayrefs.html.tt',
        {
            headers => $headers,
            rows    => $rows,
        },
        \$rates_content
    ) || die BOM::Backoffice::Request::template()->error;

    return $rates_content;
}

sub _get_moneyness_surface {
    my $self = shift;

    my $dates = [];
    my $bet   = $self->bet;
    try {
        $dates = $self->_fetch_historical_surface_date({
            back_to => 20,
            symbol  => $bet->underlying->symbol
        });
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

#Get historical vol surface dates going back a given number of historical revisions.
sub _fetch_historical_surface_date {
    my ($self, $args) = @_;

    my $back_to = $args->{back_to} || 1;
    my $symbol = $args->{symbol} or die "Must pass in symbol to fetch surface dates.";

    my $reader       = BOM::Config::Chronicle::get_chronicle_reader(1);
    my $vdoc         = $reader->get('volatility_surfaces', $symbol);
    my $current_date = $vdoc->{date};

    my @dates = ($current_date);

    for (2 .. $back_to) {
        $vdoc = $reader->get_for('volatility_surfaces', $symbol, Date::Utility->new($current_date)->epoch - 1);
        last if not $vdoc or not keys %{$vdoc};
        $current_date = $vdoc->{date};
        push @dates, $current_date;
    }

    return \@dates;
}

sub _get_volsurface {
    my $self = shift;
    my $bet  = $self->bet;

    # There's a small chance that we'll get a timeout here.
    # If we do, just carry on; we don't need to show these dates.
    my $dates = [];
    try {
        $dates = $self->_fetch_historical_surface_date({
            back_to => 20,
            symbol  => $bet->underlying->symbol
        });
    }
    catch {
        warn "Failed to fetch historical surface data (usually just a timeout): $_";
    };

    # master vol surface
    my $master_vol_url         = 'mv';
    my $master_display         = BOM::MarketData::Display::VolatilitySurface->new(surface => $self->master_surface);
    my $master_surface_content = $master_display->rmg_table_format({
        historical_dates => $dates,
        tab_id           => $bet->id . $master_vol_url,
    });

    return $master_surface_content;
}

sub _get_price {
    my ($self, $args) = @_;
    my $id = $args->{id};

    my $contract = $args->{contract};
    my $type     = $args->{type};

    my $price_content;
    my $content = $contract->is_binary ? $self->_debug_prob(['reset', $contract->$type]) : $self->_debug_price([$contract, $type]);

    BOM::Backoffice::Request::template()->process(
        'backoffice/container/tree_builder.html.tt',
        {
            id      => $id,
            content => $content,
        },
        \$price_content
    ) || die BOM::Backoffice::Request::template()->error;

    return $price_content;
}

sub _get_overview {
    my $self          = shift;
    my $number_format = $self->number_format;
    my $bet           = $self->bet;

    my @pricing_attrs = ({
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
            value => sprintf($number_format, $bet->_pricing_args->{iv} * 100) . '%'
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
            value => roundcommon(0.0001, $bet->pricing_spot - $bet->current_spot),
        },
        {
            label => 'Barrier adjustment',
            value =>
                (defined $barrier_to_compare ? roundcommon(0.0001, $bet->barriers_for_pricing->{barrier1} - $barrier_to_compare->as_absolute) : 0),
        },
    );

    # Delta for Strike
    my $atm_vol = $bet->volsurface->get_volatility({
        delta => 50,
        from  => $bet->effective_start,
        to    => $bet->date_expiry,
    });
    my ($delta_strike1, $delta_strike2) = (0, 0);
    # contracts that doesn't have a financial barrier or does not have barrier at start.
    if (not($bet->category_code eq 'digits' or $bet->category_code eq 'asian' or $bet->category_code eq 'highlowticks')) {
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
    BOM::Backoffice::Request::template()->process(
        'backoffice/container/multiple_tables.html.tt',
        {
            tables => [@tables],
        },
        \$overview
    ) || die BOM::Backoffice::Request::template()->error;

    return $overview;
}

#debug_price is for the non binary products as we do not have
#probability concept
sub _debug_price {
    my ($self, $args) = @_;

    my ($contract, $type) = @{$args};

    my $price_per_unit;
    if ($type eq 'ask_price') {
        $price_per_unit = $contract->_ask_price_per_unit;
    } else {
        $price_per_unit = max($contract->minimum_bid_price, $contract->_ask_price_per_unit - 2 * $contract->commission_per_unit);
    }

    my $table = '<ul>';

    $table .=
          '<li><a>'
        . 'commission per unit' . ' '
        . $contract->commission_per_unit
        . '</a></li><li><a>'
        . 'app markup per unit' . ' '
        . $contract->app_markup_per_unit
        . '</a></li><li><a>'
        . 'multiplier' . ' '
        . $contract->multiplier
        . '</a></li><li><a>'
        . $type
        . ' per unit' . ' '
        . $price_per_unit
        . '</a></li><li><a>'
        . $type . ' '
        . $contract->$type . '</a>';

    $table .= '</li></ul>';

    return $table;
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

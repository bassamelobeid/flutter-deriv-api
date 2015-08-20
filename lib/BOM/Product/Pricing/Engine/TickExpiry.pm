package BOM::Product::Pricing::Engine::TickExpiry;

use 5.010;
use Moose;
extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

use Cache::RedisDB;
use Math::Util::CalculatedValue::Validatable;
use List::Util qw(sum);
use YAML::XS qw(Load);
use YAML::CacheLoader;

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL => 1,
            PUT  => 1,
        };
    },
);

has coeff => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_coeff {
    my $self = shift;
    return YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom/config/files/tick_trade_coefficients.yml')->{$self->bet->underlying->symbol};
}

has _latest_ticks => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__latest_ticks {
    my $self = shift;

    my $bet = $self->bet;
    my @latest;
    if ($bet->backtest) {
        my $ticks = $bet->underlying->ticks_in_between_end_limit({
            end_time => $bet->date_start->epoch,
            limit    => 20,
        });
        @latest = map { {quote => $_->quote, epoch => $_->epoch} } sort { $a->epoch <=> $b->epoch } @$ticks;
    } else {
        my $latest = Cache::RedisDB->redis->lrange("LATEST_TICKS::" . $bet->underlying->symbol, -20, -1);
        @latest = map { Load($_) } @$latest;
    }

    return \@latest;
}

has [qw(model_markup commission_markup risk_markup tie_factor vol_proxy trend_proxy probability trend_adjustment)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_trend_adjustment {
    my $self = shift;

    #A,B,C,D are paramters that defines the pricing "surface."  The values are obtained emperically.
    my $coeff = $self->coeff;
    my $f1    = $coeff->{A} * sqrt($self->vol_proxy->amount) + $coeff->{B} * $self->vol_proxy->amount + $coeff->{C};
    my $f2    = 1 + exp($coeff->{D} * $self->trend_proxy->amount);

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'trend_adjustment',
        description => 'Trend adjustment for tick expiry contracts',
        set_by      => __PACKAGE__,
        base_amount => $f1 * (1 / $f2 - 0.5),
    });
}

sub _build_probability {
    my $self = shift;

    my $prob_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'Probability for tick expiry contracts based on the last 20 ticks',
        set_by      => __PACKAGE__,
        minimum     => 0.5,
        maximum     => 1,
        base_amount => 0.5,
    });
    if ($self->bet->pricing_code eq 'PUT') {
        $prob_cv->include_adjustment('subtract', $self->trend_adjustment);
    } else {
        $prob_cv->include_adjustment('add', $self->trend_adjustment);
    }
    $prob_cv->include_adjustment('info', $self->vol_proxy);
    $prob_cv->include_adjustment('info', $self->trend_proxy);

    if (not defined $prob_cv->peek_amount('vol_proxy') or not defined $prob_cv->peek_amount('trend_proxy')) {
        $prob_cv->add_errors({
            message           => 'Insufficient market data to calculate price',
            message_to_client => 'Insufficient market data to calculate price',
        });
    }

    return $prob_cv;
}

sub _build_vol_proxy {
    my $self = shift;

    my @latest = @{$self->_latest_ticks};
    my $proxy;
    if (@latest and @latest == 20 and abs($self->bet->date_start->epoch - $latest[0]{epoch}) < 300) {
        my $sum = 0;
        for (1 .. 19) {
            $sum += log($latest[$_]{quote} / $latest[$_ - 1]{quote})**2;
        }
        $proxy = sqrt($sum / 19);
    }
    my $proxy_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_proxy',
        description => 'volatility approximation base on last 20 ticks',
        set_by      => __PACKAGE__,
        minimum     => $self->coeff->{y_min},
        maximum     => $self->coeff->{y_max},
        defined $proxy ? (base_amount => $proxy) : (base_amount => 0.2),    # 20% vol if it ever goes wrong
    });

    if (not defined $proxy) {
        $proxy_cv->add_errors({
            message           => 'Do not have latest ticks to calculate volatility',
            message_to_client => 'Insufficient market data to calculate price.',
        });
    }

    return $proxy_cv;
}

sub _build_trend_proxy {
    my $self = shift;

    my $trend_proxy = 0;
    my $coeff       = $self->coeff;
    if ($self->vol_proxy->confirm_validity) {
        my $latest        = $self->_latest_ticks;
        my $ma_step       = $coeff->{ma_step};
        my $previous_tick = -$ma_step;
        my $avg           = sum(map { $_->{quote} } @$latest[$previous_tick .. -1]) / $ma_step;
        my $x             = ($latest->[-1]{quote} - $avg) / $latest->[-1]{quote};
        $trend_proxy = $x / $self->vol_proxy->amount;
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'trend_proxy',
        description => 'approximation for trend',
        set_by      => __PACKAGE__,
        minimum     => $coeff->{x_prime_min},
        maximum     => $coeff->{x_prime_max},
        base_amount => $trend_proxy,
    });
}

sub _build_model_markup {
    my $self = shift;

    my $model_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'model_markup',
        description => 'Model markup for Tick Expiry engine',
        set_by      => __PACKAGE__,
    });

    $model_markup->include_adjustment('reset', $self->risk_markup);
    $model_markup->include_adjustment('add',   $self->commission_markup);

    return $model_markup;
}

sub _build_commission_markup {
    my $self = shift;

    my $base_amount    = 0.0;
    my $ul             = $self->bet->underlying;
    my $market_name    = $ul->market->name;
    my $submarket_name = $ul->submarket->name;

    if ($market_name eq 'forex') {
        $base_amount = 0.025;
    }
    if ($submarket_name eq 'smart_fx') {
        $base_amount = 0.02;
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'Commission markup for tick expiry contracts. This varies by underlying.',
        set_by      => __PACKAGE__,
        base_amount => $base_amount,
    });
}

sub _build_risk_markup {
    my $self = shift;

    my $tie_adj = 0;
    my $coef    = $self->coeff;
    my $y       = $self->vol_proxy->amount;
    my $x       = $self->trend_proxy->amount;
    # we assume if you have one tie coefficent, you have all ties.
    if ($coef and $coef->{tie_A}) {
        $tie_adj = $coef->{tie_A} * $x**2 + $coef->{tie_B} + $coef->{tie_C} * $y + $coef->{tie_D} * sqrt($y);
    }

    my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'A markup for the probability of a tie in entry and exit ticks',
        set_by      => __PACKAGE__,
        minimum     => -0.1,
        # ties work in BOM's favor, so we are giving clients a slightly cheaper price.
        base_amount => -$tie_adj / 2,
    });

    $risk_markup->include_adjustment('multiply', $self->tie_factor);

    #TODO: add 3% to the markup in case the (x=trend,y=vol) is outside boundaries of the surface
    my $x_base_amount = $self->trend_proxy->base_amount;
    my $y_base_amount = $self->vol_proxy->base_amount;

    my $x_min = $coef->{x_prime_min};
    my $x_max = $coef->{x_prime_max};
    my $y_min = $coef->{y_min};
    my $y_max = $coef->{y_max};

    if ($x_base_amount > $x_max) or ($x_base_amount < $x_min) or ($y_base_amount > $y_max) or ($y_base_amount < $y_min) {
        $risk_markup->include_adjustment('multiply', 1.03) 
    }

    return $risk_markup;
}

sub _build_tie_factor {
    my $self = shift;

    my $ten_minutes_int = Time::Duration::Concise->new(interval => '10m');
    my $contract_start  = $self->bet->effective_start;
    my $start_period    = $contract_start->minus_time_interval($ten_minutes_int->seconds);
    my $end_period      = $contract_start->plus_time_interval($ten_minutes_int->seconds);
    my @economic_events = $self->get_applicable_economic_events($start_period, $end_period);
    my $factor_base     = (@economic_events) ? 0 : 0.75;

    return Math::Util::CalculatedValue::Validatable->new({
        #This is the fraction of tie value that we return to clients.
        name        => 'tie_factor',
        description => 'A constant multiplier to ties coefficient',
        set_by      => __PACKAGE__,
        base_amount => $factor_base,
    });
}

sub is_compatible {
    my $bet = shift;

    my %supported_sentiment = (
        up   => 1,
        down => 1
    );
    return unless $supported_sentiment{$bet->sentiment};
    my %symbols = map { $_ => 1 } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['forex'],
        expiry_type       => 'tick',
        contract_category => 'callput'
    );
    return unless $symbols{$bet->underlying->symbol};
    return 1;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;

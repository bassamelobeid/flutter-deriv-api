package BOM::Product::Pricing::Engine::Intraday::Index;

use Moose;
extends 'BOM::Product::Pricing::Engine::Intraday';

use YAML::XS qw(LoadFile);
use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

my $coefficients = LoadFile('/home/git/regentmarkets/bom/config/files/intraday_index_calibration_coefficient.yml');

has coefficients => (
    is      => 'ro',
    default => sub {$coefficients},
);

has pricing_vol => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_pricing_vol {
    return shift->bet->pricing_args->{iv};
}

has [qw(probability intraday_trend model_markup period_opening_value period_closing_value ticks_for_trend)] => (
    is         => 'ro',
    lazy_build => 1,
);

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

sub _build_probability {
    my $self = shift;

    my $bet      = $self->bet;
    my $coef_ref = $self->coefficients->{$self->bet->underlying->symbol};

    # if calibration coefficients are not present, we could not price
    if (not $coef_ref) {
        $bet->add_error({
            severity => 100,
            message  => format_error_string('Calibration coefficient missing', symbol => $bet->underlying->symbol),
            message_to_client =>
                localize('Trading on [_1] is suspended due to missing market data.', $bet->underlying->translated_display_name()),
        });
    }
    # give it some dummy coefficient if we don't have them
    my @coef                = $coef_ref ? @{$coef_ref} : (0.1) x 5;
    my $duration_in_minutes = $bet->pricing_args->{t} * 365 * 24 * 60;
    my $pricing_vol         = $bet->pricing_args->{iv};
    my $trend               = $self->intraday_trend->amount;

    my $factor = $trend / ($pricing_vol**0.5 * $duration_in_minutes);

    $factor = $coef[3] if ($factor < $coef[3]);
    $factor = $coef[4] if ($factor > $coef[4]);

    my $z = $coef[1] * $factor;
    #Generate the classification probability using sigmoid function
    my $boundary_classification = 1 / (1 + exp(-$z));
    #Adjust the slope and apply a flat adjustment as per the insample calibration
    my $final_adjustment = $coef[0] * $boundary_classification - $coef[0] / 2 + $coef[2];
    #Adjustment is opposite for 'down' contracts
    my $w = ($bet->sentiment eq 'up') ? 1 : -1;
    $final_adjustment *= $w;

    my $adjustment = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability_adjustment',
        description => 'theoretical probability adjustment for indices',
        set_by      => __PACKAGE__,
        base_amount => $final_adjustment,
    });

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'theoretical probability for index',
        set_by      => __PACKAGE__,
        minimum     => 0,
        maximum     => 1,
        base_amount => $self->formula->($self->_formula_args),
    });

    $prob->include_adjustment('add', $adjustment);

    return $prob;
}

sub _build_ticks_for_trend {
    my $self = shift;

    my $bet        = $self->bet;
    my $underlying = $bet->underlying;
    my $at         = $self->tick_source;
    my $how_long   = $self->_trend_interval;

    my @unchunked_ticks = @{
        $at->retrieve({
                underlying   => $underlying,
                interval     => $how_long,
                ending_epoch => $bet->date_pricing->epoch,
                fill_cache   => !$bet->backtest,
            })};

    my ($iov, $icv) = (@unchunked_ticks) ? ($unchunked_ticks[0]->{quote}, $unchunked_ticks[-1]->{quote}) : ($bet->current_spot, $bet->current_spot);
    my $iot = Math::Util::CalculatedValue::Validatable->new({
        name        => 'period_opening_value',
        description => 'First tick in intraday aggregated ticks',
        set_by      => __PACKAGE__,
        base_amount => $iov,
    });

    my $ict = Math::Util::CalculatedValue::Validatable->new({
        name        => 'period_closing_value',
        description => 'Last tick in intraday aggregated ticks',
        set_by      => __PACKAGE__,
        base_amount => $icv,
    });

    return +{
        first => $iot,
        last  => $ict
    };
}

=head2 period_opening_value

The first tick of our aggregation period, reenvisioned as a Math::Util::CalculatedValue::Validatable

=cut

sub _build_period_opening_value {
    my $self = shift;

    return $self->ticks_for_trend->{first};
}

=head2 period_closing_value

The final tick of our aggregation period, reenvisioned as a Math::Util::CalculatedValue::Validatable.

For bets which we are pricing now, it's the latest spot.

=cut

sub _build_period_closing_value {
    my $self = shift;

    return $self->ticks_for_trend->{last};
}

=head1 intraday_trend

The current observed trend in the market movements.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_trend {
    my $self = shift;

    my $trend_amount =
        int(($self->period_closing_value->amount - $self->period_opening_value->amount) / $self->period_opening_value->amount * 100000) / 5;
    my $trend = Math::Util::CalculatedValue::Validatable->new({
            name        => 'intraday_trend',
            description => 'trend over the last '
                . Time::Duration::Concise->new(
                interval => $self->bet->timeindays->amount * 86400,
                )->as_string,
            set_by      => __PACKAGE__,
            base_amount => $trend_amount,
        });
    $trend->include_adjustment('info', $self->period_closing_value);
    $trend->include_adjustment('info', $self->period_opening_value);

    return $trend;
}

sub _build_model_markup {
    my $self = shift;

    # model markup is risk_markup + commission_markup.
    # Since risk_markup will always be zero and we have a fixed commision of 3%,
    # we set model_markup to 0.03.
    my $base_amount    = 0.03;
    my $ul             = $self->bet->underlying;
    my $submarket_name = $ul->submarket->name;

    # for smart opi, it need to have commission of 4%.
    if ($submarket_name eq 'smart_opi') {
        $base_amount = 0.04;
    }

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'model_markup',
        description => 'model markup for intraday index',
        set_by      => __PACKAGE__,
        base_amount => $base_amount,
    });

    return $markup;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

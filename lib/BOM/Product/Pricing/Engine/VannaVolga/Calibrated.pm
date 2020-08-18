package BOM::Product::Pricing::Engine::VannaVolga::Calibrated;

=head1 NAME

BOM::Product::Pricing::Engine::VannaVolga::Calibrated

=head1 DESCRIPTION

Prices options using Black-Scholes with Vanna-Volga corrections with a stochastic adjustment

Ref: Bloomberg 2007 paper : Variations on the Vanna Volga Adjustment, Travis Fisher, January 26, 2007, Version 1.1

=cut

use Moose;
use namespace::autoclean;

use Moose::Util::TypeConstraints;
enum 'CalibrationModel', [qw(wystup bom-surv bom-fet bloomberg)];

extends 'BOM::Product::Pricing::Engine::VannaVolga';

=head1 ATTRIBUTES

=head2  survival_weight

Weight to apply to VV corrections.

=cut

has [qw(survival_weight vanna_correction volga_correction vega_correction display_name)] => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(calibration_model)] => (
    is         => 'ro',
    isa        => 'CalibrationModel',
    lazy_build => 1,
);

has [qw(calibration_params)] => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {a => .55, b => 0.3, c => 0.15} },
);

sub _build_calibration_model {
    my $self = shift;

    return 'bom-surv';
}

sub _build_display_name {
    my $self = shift;

    return 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated (' . $self->calibration_model . ')';
}

=head2 VV Calibration Methods

The VV model need a calibration method to deciide on the survival weights for the various corrections added to the BS price. The references for this work were :

[1] "Variations on the Vanna Volga Adjustment", Travis Fisher, January 26, 2007, Version 1.1
[2] "Vanna-Volga methods applied to FX derivatives from theory to market practice", F Bossens, G Rayee, N Skantzos, G Deelstra, May 4, 2010.
[3] "FX Options and Structured Products", U Wystup (his book).

Reason for Market Price of Greeks : We can view vega, vanna and volga as proxies for certain kinds of risk associated to the fluctuation of volatility. Trades which bring additional risk should bring additional compensation for taking the risk. On the other side, if a trade allows you to offload risk to another party you should have to compensate them. Thus the market may attach value to soem greeks. In particular, as volatility fluctuates, hedging against them becomes a necessity.

Vega and Volga are considered to be fungible while Vanna is not. As for vega, as long as participants carry out portfolio management where the vega risk is produced as a simple sum of vegas of all instruments, then vega is treated as being fungible. Now Vanna is different as it is also a derivative wrt barrier, and hence depends on the option type unlike volga and vega. As for vanna, consider a case where the spot is very close to the barrier and hence it will be knocked out with a probability of one. Thus the option will have a value zero, which would include all the values added from the greeks. However the option vanna is not zero, as it assumes a very high value as the spot approaches the barrier. Thus vanna from one source cannot necessarily be sued to hedge vanna in the remainder of a portfolio. Thus Vanna of an option is not fungible. However both volga and vega knkc out as zero at the barriers - since the value of the option at the barrier is zero independent of the volatility level, all derivatives of this value with respect to volatility are zero. Now as vega and volga are considered fungible and are independent of the option being prioced, hemce we can take a constant weight of 1 for them while as vanna needs to be reduced to zero at barrier, we take its weight as probability of survival.

However [1] also mentions an approximation to Stochastic Volatility for VV pricing, and then claims that as the option is knocked out all the greeks become zero. Hence the weights should also be 'zero' at barriers for vega and volga too. This contradicts the previous assumption of a constant weight of 1 for vega and volga. Thus a s a compromise, to take care of both these features, we take the corresponding weights as :

P(vanna) = a * lambda
P(vega) = P(volga) = b + c * lambda

Here a, b and c are calibration parameters , which are selected such as to reduce the model error against the market standard prices (Merlin in this case). 'lambda' can be probability of survival or any otehr relevant metric. Now in our study, we have taken 4 models :

Wystup : as discussed in his book [3], it has a constant weight of 0.5 for Range /UporDown and a formula to calculate the weights for Onetouch/No Touch. This gives pretty impressive results and was the best model for Single barrier contracts.

BOM_surv: This is BOM's calibration model, which is now set as a = 0.55, b = 0.3 and c = 0.15. These parameters were selected after running various sets to minimize our error against Merlin. This performed the best for two barrier contracts.

Bloomberg : This is the method mentioned by Fisher in [1]. This takes a = 1, b = c = 0.5. This did not perform as well as BOM_surv or Wystup.

BOM_fet : this mdoel takes the first exit time as a substitute for the probability of survival. This was mentioned by Bosseens in [2]. We take the average of the domestic and foreign fets and then compare the results. It wa sclose to BOM_surv but not satisfcatory enough.

Hence we weere left with 2 options : Wystup or BOM_surv. We use BOM_surv model across all bet types because Wystup's survival prob calculation are not consistent between both contract and hence break the put call parity . Also ideally the calibrations need to be checked every 2 months to maintain a better estimate to the market.


=cut

sub _build_survival_weight {
    my $self = shift;
    my $bet  = $self->bet;
    my $args = $bet->_pricing_args;

    my $vega_weight  = 1;
    my $vanna_weight = 1;
    my $volga_weight = 1;
    my $surv_prob    = 1;

    if ($bet->is_path_dependent) {

        $surv_prob = ($self->bs_probability->amount) / (exp(-$args->{r_rate} * $args->{t}));

        if ($bet->sentiment eq 'high_vol') {
            $surv_prob = (exp(-$args->{r_rate} * $args->{t}) - $self->bs_probability->amount) / (exp(-$args->{r_rate} * $args->{t}));
        }

        if ($self->calibration_model eq 'bloomberg') {
            $vanna_weight = $surv_prob;
            $vega_weight  = $volga_weight = 0.5 + 0.5 * $surv_prob;
        } elsif ($self->calibration_model eq 'wystup') {
            if ($bet->two_barriers) {
                $vega_weight = $vanna_weight = $volga_weight = .5;
            } else {
                $vega_weight = $vanna_weight = $volga_weight =
                    0.9 * $surv_prob - (0.5 * $self->vol_spread * ($self->bs_probability->amount - 0.33) / .66);
            }
        } elsif ($self->calibration_model eq 'bom-surv') {
            $vanna_weight = $self->calibration_params->{a} * $surv_prob;
            $vega_weight  = $volga_weight = $self->calibration_params->{b} + $self->calibration_params->{c} * $surv_prob;
        } elsif ($self->calibration_model eq 'bom-fet') {
            my $fet_factor = $bet->timeinyears->amount / $args->{t};
            $vanna_weight = $self->calibration_params->{a} * $fet_factor;
            $vega_weight  = $volga_weight = $self->calibration_params->{b} + $self->calibration_params->{c} * $fet_factor;
        }
    }

    return {
        vega  => $vega_weight,
        vanna => $vanna_weight,
        volga => $volga_weight,
        # this doesn't affect pricing, just to be displayed in pricing_detail popup
        survival_probability => $surv_prob,
    };
}

=head2 vanna_correction

Amount to correct the probability for Vanna

=cut

sub _build_vanna_correction {
    my $self = shift;

    my $vanna_correction = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vanna_correction',
        description => 'Correction for vanna cost',
        set_by      => $self->display_name,
        base_amount => 0,
    });

    # Can probably add a builder for this outside for more detail.
    my $survival_weight = Math::Util::CalculatedValue::Validatable->new({
        name        => 'survival_weight',
        description => 'The indicated survival weight',
        set_by      => $self->display_name,
        base_amount => $self->survival_weight->{vanna},
    });

    my $bet_greeks = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bet_vanna',
        description => 'The vanna of our exotic',
        set_by      => $self->display_name,
        base_amount => $self->bet_greeks->{vanna},
    });

    # Build this elsewhere, too?
    my $greek_market_prices = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vanna_market_price',
        description => 'The indicated market price per unit of vanna',
        set_by      => $self->display_name,
        base_amount => $self->greek_market_prices->{vanna},
    });

    $vanna_correction->include_adjustment('reset',    $survival_weight);
    $vanna_correction->include_adjustment('multiply', $bet_greeks);
    $vanna_correction->include_adjustment('multiply', $greek_market_prices);

    return $vanna_correction;
}

=head2 volga_correction

Amount to correct the probability for Volga

=cut

sub _build_volga_correction {
    my $self = shift;

    my $volga_correction = Math::Util::CalculatedValue::Validatable->new({
        name        => 'volga_correction',
        description => 'Correction for volga cost',
        set_by      => $self->display_name,
        base_amount => 0,
    });

    # Can probably add a builder for this outside for more detail.
    my $survival_weight = Math::Util::CalculatedValue::Validatable->new({
        name        => 'survival_weight',
        description => 'The indicated survival weight',
        set_by      => $self->display_name,
        base_amount => $self->survival_weight->{volga},
    });

    my $bet_greeks = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bet_volga',
        description => 'The volga of our exotic',
        set_by      => $self->display_name,
        base_amount => $self->bet_greeks->{volga},
    });

    # Build this elsewhere, too?
    my $greek_market_prices = Math::Util::CalculatedValue::Validatable->new({
        name        => 'volga_market_price',
        description => 'The indicated market price per unit of volga',
        set_by      => $self->display_name,
        base_amount => $self->greek_market_prices->{volga},
    });

    $volga_correction->include_adjustment('reset',    $survival_weight);
    $volga_correction->include_adjustment('multiply', $bet_greeks);
    $volga_correction->include_adjustment('multiply', $greek_market_prices);

    return $volga_correction;
}

=head2 vega_correction

Amount to correct for Vega used to make the matrix soluble.

=cut

sub _build_vega_correction {
    my $self = shift;

    my $vega_correction = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vega_correction',
        description => 'Correction for vega cost',
        set_by      => $self->display_name,
        base_amount => 0,
    });

    # Can probably add a builder for this outside for more detail.
    my $survival_weight = Math::Util::CalculatedValue::Validatable->new({
        name        => 'survival_weight',
        description => 'The indicated survival weight',
        set_by      => $self->display_name,
        base_amount => $self->survival_weight->{vega},
    });

    my $bet_greeks = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bet_vega',
        description => 'The vega of our exotic',
        set_by      => $self->display_name,
        base_amount => $self->bet_greeks->{vega},
    });

    # Build this elsewhere, too?
    my $greek_market_prices = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vega_market_price',
        description => 'The indicated market price per unit of vega',
        set_by      => $self->display_name,
        base_amount => $self->greek_market_prices->{vega},
    });

    $vega_correction->include_adjustment('reset',    $survival_weight);
    $vega_correction->include_adjustment('multiply', $bet_greeks);
    $vega_correction->include_adjustment('multiply', $greek_market_prices);

    return $vega_correction;
}

__PACKAGE__->meta->make_immutable;

1;

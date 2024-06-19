package BOM::Product::Pricing::Engine::VannaVolga;

=head1 NAME

BOM::Product::Pricing::Engine::VannaVolga


=head1 DESCRIPTION

A Moose base class which defines the interface for our Vanna Volga Pricers

You will probably just get the BS price if you try to instantiate this directly.

=cut

=head1 PRICER DESCRIPTION

The Vanna Volga method has been popularized as a way of pricing botyh vanilla and exotic options given a very limited amount of market data.The best justified application of the method is to vainall options, however as we see it can be successfully adopted for first generation exotics. Its ease of implementation and computatinal efficiency makes it a favorite among other choices.

The  model extends the world of Black Scholes to include volatility surface skewness and convexity to price an option. It does this by introducing the concept of "correction" - where market corrections are added to the base Black Scholes values. The corrections can be used to reflect anything, from an intuitive shift to market related news effects, fundamentals etc. This is a very practical method and has found wide range of applicatins, including with the traders and in the Quantitative world. We take a quantitative approach with the model, with a goal of using a standard model for vanilla and exotic options. In our study, we have taken Merlin prices as market standards, and calibrate our model against this pricer. This model is based on the concept of adding 3 major corrections to the Black Scholes value, the Vega, Vanna and Volga correections.

Most of the literature referred during our work have ignored the Vega correction, citing vey small correction values as the reason. We howver take that correction into account. SO the basic strucuture of a Vanna Volga pricer is :

VV Price = BS price + Vega Correction + Vanna correction + Volga Correction.

A loose assumption made in the VV pricer is that a Risk Reversal has volga = 0 and a ButterFly has vanna = 0. Thus all teh vanna correction comes from RR, which measures the skewness of the vol smile. All the volga correction comes from BF, measuring the convexity of the volsmile. Thus adding the Vanna and Volga corrections take care of the skewness and convexity, hence bring the BS value much closer to the market values.

Breifly touching on the corrections, we take Vanna correction = correction weight * Vanna of the option being priced * cost per unit Vanna.

For cost per unit Vanna, we take the 25D RR market prices and BS prices. The assumption of an RR having Volga=0, means that the difference in the two prices is due to Vanna. Also we can calculate the Vanna of the  25D RR. Hence cost per unit of Vanna = (Market price of 25D RR - BS price of 25D RR)/Vanna of 25D RR.

Similarly we find the cost per unit of Volga and Vega. The Vanna, Vega and Volga of the option being priced can be easily calculated using closed form formulas. So the only thing remaining is the correction weight. There are different methods of achieveing the correction weights and there is no market consensus on it. This part is explained in detail in the calibration part of the code base in Calibrated.pm

So after getting all the desired values, we can now add these corrections to the BS value and get our market price.

=cut

=head1 REFERENCES

[1] Travis Fisher, "Variations on the Vanna Volga Adjustment", January 26, 2007, Version 1.1

[2] Uwe Wystup, "Vanna-Volga Pricing", MathFinance AG, 30 June 2008

[3] Kurt Smith, his discussions and patent on VV pricing using the concept of Estimated Stoppage Time.

[4] A, Castgana and F Mercurio, "Consistent Pricing of FX Options", 2005.

[5] F Bossens, G Rayee, N Skantzos and G Deelstra, "Vanna Volga methods applied to FX derivatives: from theory to maket practice", May 4, 2010.

[6] Y Shkolnikov, "Generalized Vanna Volga Method and its Applications", Numerix Quantitative Research, June 25, 2009.

=cut

use Moose;
use namespace::autoclean;

extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::RiskMarkup';
with 'BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios';

use BOM::Product::Pricing::Engine::BlackScholes;

=head1 ATTRIBUTES

=cut

has [qw( alpha beta gamma market_supplement vanna_correction volga_correction vega_correction )] => (
    is         => 'ro',
    lazy_build => 1,
);

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            RANGE    => 1,
            UPORDOWN => 1,
            ONETOUCH => 1,
            NOTOUCH  => 1,
        };
    },
);

=head2 market_supplement

Total amount to adjust the BS probability for our greeks. This is the total correction that needs to be added to the BS price to give a market price.

=cut

sub _build_market_supplement {
    my $self = shift;

    my $market_supp = Math::Util::CalculatedValue::Validatable->new({
        name        => 'market_supplement',
        description => 'The market supplement to BS pricing.',
        set_by      => 'BOM::Product::Pricing::Engine::VannaVolga',
    });

    $market_supp->include_adjustment('reset', $self->vanna_correction);
    $market_supp->include_adjustment('add',   $self->volga_correction);
    $market_supp->include_adjustment('add',   $self->vega_correction);

    return $market_supp;
}

=head2 alpha

The cost per unit of volga at the estimated stopping time. See the explanation at the sub greek_market_prices for further explanation.

=cut

sub _build_alpha {
    my $self = shift;

    return $self->greek_market_prices->{volga};
}

=head2 beta

The cost per unit of vanna at the estmiated stopping time. See the explanation at the sub greek_market_prices for further explanation.

=cut

sub _build_beta {
    my $self = shift;

    return $self->greek_market_prices->{vanna};
}

=head2 _build_gamma

The cost per unit of vega at the estimated stopping time. See the explanation at the sub greek_market_prices for further explanation.

=cut

sub _build_gamma {
    my $self = shift;

    return $self->greek_market_prices->{vega};
}

=head1 METHODS

=head2 probability

Returns the probability of a bet to win. Adds the market supplement, which is just the weighted sum of all the corrections.

For parity with other pricing engines, you can send in a set of pricing args, but this should likely be reconsidered.

=cut

sub _build_probability {
    my $self = shift;

    my $ctv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'corrected_theoretical_value',
        description => 'Corrected theoretical value per our Vanna-Volga',
        set_by      => 'BOM::Product::Pricing::Engine::VannaVolga',
        minimum     => 0,
        maximum     => 1,
    });

    $ctv->include_adjustment('reset', $self->base_probability);
    $ctv->include_adjustment('add',   $self->risk_markup);

    return $ctv;
}

has base_probability => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_base_probability {
    my $self = shift;

    my $base_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'base_probability',
        description => 'Corrected theoretical value per our Vanna-Volga',
        set_by      => 'BOM::Product::Pricing::Engine::VannaVolga',
        minimum     => 0,
        maximum     => 1,
    });

    # If the market supplement would absolutely drive us out of [0,1]
    # Then it is nonsense to be ignored.
    if ($self->market_supplement->amount <= -0.5 || $self->market_supplement->amount >= 1) {
        $base_probability->include_adjustment('reset', $self->no_business_probability);
    } else {
        $base_probability->include_adjustment('reset', $self->bs_probability);
        $base_probability->include_adjustment('add',   $self->market_supplement);
    }

    return $base_probability;
}

sub _build_vanna_correction {
    my $vanna = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vanna_correction',
        description => 'Unimplemented vanna correction',
        base_amount => 0,
        set_by      => 'Price::Engine::VannaVolga'
    });
    return $vanna;
}

sub _build_volga_correction {
    my $volga = Math::Util::CalculatedValue::Validatable->new({
        name        => 'volga_correction',
        description => 'Unimplemented volga correction',
        base_amount => 0,
        set_by      => 'Price::Engine::VannaVolga'
    });
    return $volga;
}

sub _build_vega_correction {
    my $vega = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vega_correction',
        description => 'Unimplemented vega correction',
        base_amount => 0,
        set_by      => 'Price::Engine::VannaVolga'
    });
    return $vega;
}

__PACKAGE__->meta->make_immutable;
1;

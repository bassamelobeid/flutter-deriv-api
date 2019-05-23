package BOM::Product::Role::Lookback;

use Moose::Role;
with 'BOM::Product::Role::NonBinary';

use Time::Duration::Concise;
use List::Util qw(min max first);
use Format::Util::Numbers qw/financialrounding/;
use LandingCompany::Commission qw(get_underlying_base_commission);
use LandingCompany::Registry;

use BOM::Product::Static;
use BOM::Market::DataDecimate;

use constant {
    MINIMUM_ASK_PRICE_PER_UNIT  => 0.50,
    MINIMUM_BID_PRICE           => 0,      # can't go negative
    MINIMUM_COMMISSION_PER_UNIT => 0.01,
};

=head2 user_defined_multiplier
We round price per unit to the nearest cent before multiplying it with the multiplier
=cut

has user_defined_multiplier => (
    is      => 'ro',
    default => 1,
);

# forward declaration for 'requires' to work in BOM::Product::Role::NonBinary
sub multiplier;

override '_build_ask_price' => sub {
    my $self = shift;

    # for lookbacks, we are setting a minimum_ask_price_per_unit and a minimum_commission_per_unit.
    # hence, the ask price is a simple price per unit multiplied by number of units.
    my $ask_price = financialrounding('price', $self->currency, $self->_ask_price_per_unit) * $self->multiplier;

    # publish ask price to pricing server
    $self->_publish({ask_price => $ask_price});

    return $ask_price;
};

override _build_theo_price => sub {
    my $self = shift;

    return $self->pricing_engine->theo_price;
};

override _build_base_commission => sub {
    return 0.02;    # a static 2% commission across the board. This is done to enable sellback.
};

=head2 multiplier
The number of units.
=cut

has multiplier => (
    is       => 'ro',
    required => 1,
    isa      => 'Num',
);

sub minimum_ask_price_per_unit {
    return MINIMUM_ASK_PRICE_PER_UNIT;
}

sub minimum_bid_price {
    return MINIMUM_BID_PRICE;
}

sub minimum_commission_per_unit {
    return MINIMUM_COMMISSION_PER_UNIT;
}

sub get_ohlc_for_period {
    my $self = shift;

    # date_start + 1 because the first tick of the contract is the next tick.
    my $start_epoch = $self->date_start->epoch + 1;
    my $end_epoch = $self->date_pricing->is_after($self->date_expiry) ? $self->date_expiry->epoch : $self->date_pricing->epoch;
    $end_epoch = max($start_epoch, $end_epoch);

    return $self->underlying->get_high_low_for_period({
        start => $start_epoch,
        end   => $end_epoch
    });
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Lookback';
}

sub _build_payout {
    return 0;
}

has date_start_plus_1s => (
    is         => 'rw',
    lazy_build => 1
);

# This is because for lookback, we do not want to inlcude tick at the date_start
sub _build_date_start_plus_1s {
    my $self = shift;
    return $self->date_start->plus_time_interval('1s');
}

override shortcode => sub {
    my $self = shift;

    my $shortcode_date_start = $self->date_start->epoch;

    my $shortcode_date_expiry =
        ($self->fixed_expiry)
        ? $self->date_expiry->epoch . 'F'
        : $self->date_expiry->epoch;

    # TODO We expect to have a valid bet_type, but there may be codepaths which don't set this correctly yet.
    my $contract_type = $self->bet_type // $self->code;

    my @shortcode_elements = ($contract_type, $self->underlying->symbol, $self->multiplier, $shortcode_date_start, $shortcode_date_expiry);

    return uc join '_', @shortcode_elements;
};

1;

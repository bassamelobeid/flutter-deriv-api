package BOM::Product::Role::Lookback;

use Moose::Role;
use Time::Duration::Concise;
use List::Util qw(min max first);
use Format::Util::Numbers qw/financialrounding/;
use YAML::XS qw(LoadFile);
use LandingCompany::Commission qw(get_underlying_base_commission);
use LandingCompany::Registry;

my $minimum_multiplier_config = LoadFile('/home/git/regentmarkets/bom/config/files/lookback_minimum_multiplier.yml');

=head2 spot_min

The lowest spot price throughout the contract period.

=head2 spot_max

The highest spot price throughout the contract period.

=cut

has [qw(spot_min spot_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 multiplier

The number of units.

=cut

has multiplier => (
    is  => 'ro',
    isa => 'Num',
);

=head2 minimum_multiplier

The minimum allowed unit.

=cut

has minimum_multiplier => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

=head2 factor

This is the cryptocurrency factor. Currently set to 0.01.

=cut

has factor => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

=head2 base_commission

For lookback options, base commission is the static commission
charged per underlying basis.

=cut

has base_commission => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_base_commission {
    my $self = shift;

    my $args = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);
    return $underlying_base;
}

sub _build_factor {
    my $self          = shift;
    my $currency_type = LandingCompany::Registry::get_currency_type($self->currency);
    my $factor        = $currency_type eq 'crypto' ? $minimum_multiplier_config->{'crypto_factor'} : 1;
    return $factor;
}

sub _build_minimum_multiplier {
    my $self               = shift;
    my $symbol             = $self->underlying->symbol;
    my $minimum_multiplier = $minimum_multiplier_config->{$symbol} / $self->factor;

    return $minimum_multiplier // 0;
}

has [qw(spot_min_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_spot_min_max {
    my $self = shift;

    # date_start + 1 because the first tick of the contract is the next tick.
    my $start = $self->date_start->epoch + 1;
    my $end = max($start, $self->effective_start->epoch);

    my ($high, $low) = @{
        $self->underlying->get_high_low_for_period({
                start => $start,
                end   => $end,
            })}{'high', 'low'};

    my $high_low = {
        high => $high // $self->pricing_spot,
        low  => $low  // $self->pricing_spot,
    };

    return $high_low;
}

sub _build_spot_min {
    my $self = shift;

    return $self->spot_min_max->{low};
}

sub _build_spot_max {
    my $self = shift;

    return $self->spot_min_max->{high};
}

sub _build_priced_with_intraday_model {
    return 0;
}

sub get_ohlc_for_period {
    my $self = shift;

    my $start_epoch = $self->date_start->epoch;
    my $end_epoch = $self->date_pricing->is_after($self->date_expiry) ? $self->date_expiry->epoch : $self->date_pricing->epoch;

    return $self->underlying->get_high_low_for_period({
        start => $start_epoch + 1,
        end   => $end_epoch
    });
}

override _build_ask_price => sub {
    my $self = shift;

    my $theo_price = $self->pricing_engine->theo_price;

    my $commission = $theo_price * $self->base_commission;
    $commission = max(0.01, $commission);

    my $final_price = max(0.50, ($theo_price + $commission));

    #Here to avoid issue due to rounding strategy, we round the price of unit of min multiplier.
    #Example, for fiat it is 0.1.
    return financialrounding('price', $self->currency, $final_price) * $self->multiplier;
};

override _build_bid_price => sub {
    my $self = shift;

    if ($self->is_expired) {
        return financialrounding('price', $self->currency, $self->value);
    }

    my $theo_price = $self->pricing_engine->theo_price * $self->multiplier;

    return financialrounding('price', $self->currency, $theo_price * (1 - $self->base_commission));
};

override _validate_price => sub {
    my $self = shift;

    my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

    my @err;
    if (not $self->ask_price or $self->ask_price == 0) {
        push @err,
            {
            message           => 'Lookbacks ask price can not be zero .',
            message_to_client => [$ERROR_MAPPING->{InvalidLookbacksPrice}],
            };
    }

    return @err;
};

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Lookback';
}

sub _build_payout {
    return 0;
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

override allowed_slippage => sub {
    my $self = shift;

    #We will use same value as binary for now.
    return 0.01;
};

1;

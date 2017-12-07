package BOM::Product::Role::Lookback;

use Moose::Role;
use Time::Duration::Concise;
use List::Util qw(min max first);
use Format::Util::Numbers qw/financialrounding/;
use YAML::XS qw(LoadFile);
use LandingCompany::Commission qw(get_underlying_base_commission);

use BOM::Product::Static;

my $multiplier_config = LoadFile('/home/git/regentmarkets/bom/config/files/lookback_contract_multiplier.yml');

has [qw(spot_min spot_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

has unit => (
    is  => 'ro',
    isa => 'Num',
);

has multiplier => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has lookback_base_commission => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_lookback_base_commission {
    my $self = shift;
    my $args = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);
    return $underlying_base;
}

sub _build_multiplier {
    my $self   = shift;
    my $symbol = $self->underlying->symbol;
    return $multiplier_config->{$symbol};
}

sub _build_spot_min {
    my $self = shift;

    my $spot_min = @{
        $self->underlying->get_high_low_for_period({
                start => $self->date_start->epoch + 1,
                end   => $self->date_expiry->epoch,
            })}{'low'} // $self->pricing_spot;

    return $spot_min;
}

sub _build_spot_max {
    my $self = shift;

    my $spot_max = @{
        $self->underlying->get_high_low_for_period({
                start => $self->date_start->epoch + 1,
                end   => $self->date_expiry->epoch,
            })}{'high'} // $self->pricing_spot;

    return $spot_max;
}

sub _build_priced_with_intraday_model {
    return 0;
}

sub get_ohlc_for_period {
    my $self = shift;

    my $start_epoch = $self->date_start->epoch;
    my $end_epoch;
    if ($self->date_pricing->is_after($self->date_expiry)) {
        $end_epoch = $self->expiry_daily ? $self->date_expiry->truncate_to_day->epoch : $self->date_settlement->epoch;
    } else {
        $end_epoch = $self->date_pricing->epoch;
    }

    return $self->underlying->get_high_low_for_period({
        start => $start_epoch + 1,
        end   => $end_epoch
    });
}

override _build_theo_price => sub {
    my $self = shift;

    if ($self->is_expired) {
        my $final_price = $self->value;
        return $final_price > 0 ? $final_price * $self->unit * $self->multiplier : 0;
    }

    return $self->pricing_engine->theo_price * $self->unit * $self->multiplier;
};

override _build_ask_price => sub {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->theo_price * (1 + $self->lookback_base_commission));
};

override _build_bid_price => sub {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->theo_price * (1 - $self->lookback_base_commission));
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

sub is_binary {
    return 0;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Lookback';
}

override shortcode => sub {
    my $self = shift;

    my $shortcode_date_start  = $self->date_start->epoch;
    my $shortcode_date_expiry = $self->date_expiry->epoch;

    # TODO We expect to have a valid bet_type, but there may be codepaths which don't set this correctly yet.
    my $contract_type = $self->bet_type // $self->code;
    my @shortcode_elements = ($contract_type, $self->underlying->symbol, $self->unit, $shortcode_date_start, $shortcode_date_expiry);

    if (defined $self->supplied_barrier and $self->barrier_at_start) {
        push @shortcode_elements, ($self->_barrier_for_shortcode_string($self->supplied_barrier), 0);
    }

    if (defined $self->multiplier) {
        push @shortcode_elements, $self->multiplier;
    }

    return uc join '_', @shortcode_elements;
};

override allowed_slippage => sub {
    my $self = shift;

    #We will use same value as binary for now.
    return 0.01;
};

1;

package BOM::Product::Role::Lookback;

use Moose::Role;
use Time::Duration::Concise;
use List::Util qw(min max first);
use Format::Util::Numbers qw/financialrounding/;

use BOM::Product::Static;

has [qw(ticks_for_lookbacks spot_min spot_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

has unit => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_ticks_for_lookbacks {

    my $self      = shift;
    my $end_epoch = $self->date_expiry->epoch;

    my @ticks_since_start = @{
        $self->underlying->ticks_in_between_start_end({
                start_time => $self->date_start->epoch,
                end_time   => $end_epoch,
            })};

    return \@ticks_since_start;
}

sub _build_spot_min {
    my $self = shift;

    my @ticks_since_start = @{$self->ticks_for_lookbacks};

    my @quote = map { $_->{quote} } @ticks_since_start;
    my $min = min(@quote);

    return $min;
}

sub _build_spot_max {
    my $self = shift;

    my @ticks_since_start = @{$self->ticks_for_lookbacks};

    my @quote = map { $_->{quote} } @ticks_since_start;
    my $max = max(@quote);

    return $max;
}

sub _build_priced_with_intraday_model {
    return 0;
}

override _build_theo_price => sub {
    my $self = shift;

    return $self->pricing_engine->theo_price * $self->unit;
};

override _build_ask_price => sub {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->theo_price);
};

override _build_bid_price => sub {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->theo_price);
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

override is_binary => sub {
    return 0;
};

override shortcode => sub {
    my $self = shift;

    my $shortcode_date_start = (
               $self->is_forward_starting
            or $self->starts_as_forward_starting
    ) ? $self->date_start->epoch . 'F' : $self->date_start->epoch;
    my $shortcode_date_expiry =
          ($self->tick_expiry)  ? $self->tick_count . 'T'
        : ($self->fixed_expiry) ? $self->date_expiry->epoch . 'F'
        :                         $self->date_expiry->epoch;

    # TODO We expect to have a valid bet_type, but there may be codepaths which don't set this correctly yet.
    my $contract_type = $self->bet_type // $self->code;
    my @shortcode_elements = ($contract_type, $self->underlying->symbol, $self->unit, $shortcode_date_start, $shortcode_date_expiry);

    if ($self->two_barriers) {
        push @shortcode_elements, map { $self->_barrier_for_shortcode_string($_) } ($self->supplied_high_barrier, $self->supplied_low_barrier);
    } elsif (defined $self->supplied_barrier and $self->barrier_at_start) {
        push @shortcode_elements, ($self->_barrier_for_shortcode_string($self->supplied_barrier), 0);
    }

    return uc join '_', @shortcode_elements;
};

override allowed_slippage => sub {
    my $self = shift;

    #We will use same value as binary for now.
    return 0.01;
};

1;

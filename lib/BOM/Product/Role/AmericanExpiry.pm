package BOM::Product::Role::AmericanExpiry;

use Moose::Role;
use BOM::Product::Static;

use Postgres::FeedDB::Spot::Tick;
use List::Util qw/min max/;
use Scalar::Util qw/looks_like_number/;

override is_expired => sub {
    my $self = shift;

    if ($self->has_user_defined_barrier and not $self->category->allow_atm_barrier) {
        my @barriers = $self->two_barriers ? ($self->supplied_high_barrier, $self->supplied_low_barrier) : ($self->supplied_barrier);
        if (grep { (looks_like_number($_) and $_ == 0) or $_ eq 'S0P' } @barriers) {
            $self->_add_error({
                alert             => 1,
                severity          => 100,
                message           => 'Path-dependent barrier at spot at start',
                message_to_client => [BOM::Product::Static::get_error_mapping()->{AlreadyExpired}],
            });
            # Was expired at start, making it an unfair bet, so value goes to 0 without regard to bet conditions.
            $self->value(0);
            return 1;
        }
    }

    if ($self->hit_tick or $self->is_after_expiry) {
        $self->check_expiry_conditions;
        return 1;
    }

    return 0;

};

has hit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

# It seems like you would want this on the Underlying..
# but since they are cached and shared, it gets much messier.
sub _build_hit_tick {
    my $self = shift;

    return undef unless $self->entry_tick;

    my $start_time     = $self->date_start->epoch + 1;
    my %hit_conditions = (
        start_time => $start_time,
        end_time   => max($start_time, min($self->date_pricing->epoch, $self->date_expiry->epoch)),
    );

    if ($self->two_barriers) {
        $hit_conditions{higher} = $self->high_barrier->as_absolute;
        $hit_conditions{lower}  = $self->low_barrier->as_absolute;
    } elsif ($self->barrier->pip_difference > 0) {
        $hit_conditions{higher} = $self->barrier->as_absolute;
    } else {
        $hit_conditions{lower} = $self->barrier->as_absolute;
    }

    return $self->_get_tick_expiry_hit_tick(%hit_conditions)  if $self->tick_expiry;
    return $self->underlying->breaching_tick(%hit_conditions) if $self->is_intraday;
    # TODO: remove this when we are no longer dependent on official ohlc for settlement.
    return $self->_get_hit_tick_from_ohlc(%hit_conditions);
}

has ok_through_expiry => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ok_through_expiry {
    my $self = shift;

    return 0 unless $self->is_after_expiry;
    return 0 unless $self->exit_tick;
    return 0 if $self->expiry_type eq 'intraday' and $self->exit_tick->quote != $self->_ohlc_for_contract_period->{close};
    return 1;
}

sub close_tick {
    my $self = shift;

    return $self->hit_tick if ($self->category->code ne 'highlowticks');

    if ($self->hit_tick and $self->_selected_tick) {
        return $self->hit_tick->epoch < $self->_selected_tick->epoch ? $self->_selected_tick : $self->hit_tick;
    }

    return;
}

sub _get_tick_expiry_hit_tick {
    my ($self, %args) = @_;

    my @ticks_since_start = @{$self->get_ticks_for_tick_expiry};
    my $tick;

    for (my $i = 1; $i <= $#ticks_since_start; $i++) {
        if (   (defined $args{higher} and $ticks_since_start[$i]->quote >= $args{higher})
            or (defined $args{lower} and $ticks_since_start[$i]->quote <= $args{lower}))
        {
            $tick = $ticks_since_start[$i];
            last;
        }
    }

    return $tick;
}

has _ohlc_for_contract_period => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__ohlc_for_contract_period {
    my $self = shift;

    # exlusive of tick at contract start.
    my $start_epoch = $self->date_start->epoch + 1;

    my $end_epoch = max($self->date_pricing->epoch, $start_epoch);
    if ($self->date_pricing->is_after($self->date_expiry)) {
        # For daily contract, to include the official ohlc on the expiry date, you should include the full day of the expiry date [ie is how our db is handling daily ohlc].
        # Otherwise, it will just include unofficial ohlc on the expiry date.
        # In Postgres::FeedDB::Spot::DatabaseAPI::get_ohlc_data_for_period, it will move the day to end of the day.
        $end_epoch = $self->expiry_daily ? $self->date_expiry->truncate_to_day->epoch : $self->date_settlement->epoch;
    }

    return $self->underlying->get_high_low_for_period({
        start => $start_epoch,
        end   => $end_epoch,
    });

}

sub _get_hit_tick_from_ohlc {
    my ($self, %args) = @_;

    my $ohlc = $self->_ohlc_for_contract_period;
    my $hit_quote;

    if ($args{higher} and $ohlc->{high} and $ohlc->{high} >= $args{higher}) {
        $hit_quote = $ohlc->{high};
    } elsif ($args{lower} and $ohlc->{low} and $ohlc->{low} <= $args{lower}) {
        $hit_quote = $ohlc->{low};
    }

    # since ohlc has no timestamp on the tick, we will have to use the end of period
    return Postgres::FeedDB::Spot::Tick->new({
            symbol => $self->underlying->symbol,
            epoch  => $args{end_time},
            quote  => $hit_quote,
        }) if defined $hit_quote;

    return;
}
1;

package BOM::Product::Role::AmericanExpiry;

use Moose::Role;

use BOM::Platform::Context qw(localize);

sub _build_is_expired {
    my $self = shift;
    my $is_expired;
    my ($barrier, $barrier2) =
        $self->two_barriers ? ($self->high_barrier->as_absolute, $self->low_barrier->as_absolute) : ($self->barrier->as_absolute);
    my $spot = $self->entry_spot;
    if ($spot and ($spot == $barrier or ($barrier2 and $spot == $barrier2))) {
        $self->_add_error({
            alert             => 1,
            severity          => 100,
            message           => 'Path-dependent barrier at spot at start',
            message_to_client => localize("This contract has already expired."),
        });
        # Was expired at start, making it an unfair bet, so value goes to 0 without regard to bet conditions.
        $self->value(0);
        $is_expired = 1;
    } else {
        $is_expired = $self->check_expiry_conditions;
    }

    return $is_expired;
}

sub _build_is_settleable {
    my $self = shift;

    return $self->is_expired // 0;

}

has hit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

# It seems like you would want this on the Underlying..
# but since they are cached and shared, it gets much messier.
sub _build_hit_tick {
    my $self = shift;

    my $tick;

    if ($self->is_expired && (($self->payouttime ne 'hit' xor $self->value))) {
        my %hit_conditions =
            ($self->two_barriers)
            ? (
            higher => $self->high_barrier->as_absolute,
            lower  => $self->low_barrier->as_absolute,
            )
            : ($self->barrier->pip_difference > 0) ? (higher => $self->barrier->as_absolute)
            :                                        (lower => $self->barrier->as_absolute);

        # do not include current tick as the contract starts at next tick.
        $hit_conditions{start_time} = $self->date_start->epoch + 1;
        $hit_conditions{end_time}   = $self->date_expiry;
        $tick                       = $self->underlying->breaching_tick(%hit_conditions);
    }

    return $tick;
}

sub get_high_low_for_contract_period {
    my $self = shift;

    my ($high, $low, $close);
    my $ok_through_expiry = 0;                                     # Must be confirmed.
    my $exit_tick = $self->is_after_expiry && $self->exit_tick;    # Can still be undef if the tick is not yet in the DB.
    if (not $self->pricing_new and $self->entry_tick and $self->entry_tick->epoch < $self->date_pricing->epoch) {
        my $start_epoch = $self->date_start->epoch + 1;            # exlusive of tick at contract start.

        my $end_epoch;

        if ($self->date_pricing->is_after($self->date_expiry)) {
            # For daily contract, to include the official ohlc on the expiry date, you should include the full day of the expiry date [ie is how our db is handling daily ohlc]. Otherwise, it will just include unofficial ohlc on the expiry date
            # In Postgres::FeedDB::Spot::DatabaseAPI::get_ohlc_data_for_period, it will move the day to end of the day.

            $end_epoch = $self->expiry_daily ? $self->date_expiry->truncate_to_day->epoch : $self->date_settlement->epoch;
        } else {
            $end_epoch = $self->date_pricing->epoch;
        }

        ($high, $low, $close) = @{
            $self->underlying->get_high_low_for_period({
                    start => $start_epoch,
                    end   => $end_epoch,
                })}{'high', 'low', 'close'};
        # The two intraday queries run off different tables, so we have to make sure our consistent
        # exit tick was included. expiry_daily may have differences, but should be fine anyway.
        $ok_through_expiry = 1 if ($exit_tick and $close and ($self->expiry_daily or $exit_tick->quote == $close));
    }

    return ($high, $low, $ok_through_expiry);
}

1;

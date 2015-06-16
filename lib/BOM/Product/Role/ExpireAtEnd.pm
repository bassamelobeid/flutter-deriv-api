package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;

use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);

sub _build_is_expired {
    my $self = shift;

    return 0 if (not $self->is_after_expiry);

    my $is_expired = 1;
    if ($self->exit_tick) {
        $self->check_expiry_conditions;
    } else {
        $self->value(0);
        $self->add_errors({
            severity          => 100,
            message           => 'Missing settlement tick for [' . $self->date_expiry->iso8601 . '/' . $self->underlying->symbol . ']',
            message_to_client => localize('The database is not yet updated with settlement data.'),
        });
    }
    return $is_expired;
}

has exit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_exit_tick {
    my $self = shift;

    my $underlying = $self->underlying;
    my $exchange   = $self->exchange;

    my $exit_tick;
    if ($self->tick_expiry) {
        my $tick_number       = $self->ticks_to_expiry;
        my @ticks_since_start = @{
            $underlying->ticks_in_between_start_limit({
                    start_time => $self->date_start->epoch + 1,
                    limit      => $tick_number,
                })};
        if (@ticks_since_start == $tick_number) {
            $exit_tick = $ticks_since_start[-1];
            $self->date_expiry(Date::Utility->new($exit_tick->epoch));
        }
    } elsif ($self->expiry_daily) {
        # Expiration based on daily OHLC
        $exit_tick = $underlying->closing_tick_on($self->date_expiry->date);
    } else {
        $exit_tick = $underlying->tick_at($self->date_expiry->epoch);
    }

    if ($exit_tick and my $entry_tick = $self->entry_tick) {
        my ($first_date, $last_date) = map { Date::Utility->new($_) } ($entry_tick->epoch, $exit_tick->epoch);
        my $max_delay = $underlying->max_suspend_trading_feed_delay;
        # We should not have gotten here otherwise.
        if (not $first_date->is_before($last_date)) {
            $self->add_errors({
                severity => 100,
                alert    => 1,
                message  => 'Start tick ['
                    . $first_date->db_timestamp
                    . '] is not before expiry tick ['
                    . $last_date->db_timestamp . '] on '
                    . $underlying->symbol,
                message_to_client => localize("Missing market data for contract period."),
            });
        }
        my $end_delay = Time::Duration::Concise->new(interval => $self->date_expiry->epoch - $last_date->epoch);

        if ($self->expiry_daily and not $underlying->use_official_ohlc) {
            if (    not $self->is_path_dependent
                and not $self->_has_ticks_before_close($exchange->closing_on($self->date_expiry)))
            {
                $self->add_errors({
                    severity          => 99,
                    alert             => 1,
                    message           => 'Missing ticks at close of ' . $self->date_expiry->iso8601 . ' on ' . $underlying->symbol,
                    message_to_client => localize("Missing market data for exit spot."),
                });
            }
        } elsif ($end_delay->seconds > $max_delay->seconds) {
            $self->add_errors({
                severity => 99,
                alert    => 1,
                message  => 'Exit tick too far away ['
                    . $end_delay->as_concise_string
                    . ', permitted: '
                    . $max_delay->as_concise_string . '] on '
                    . $underlying->symbol . ' at '
                    . $self->date_expiry->iso8601,
                message_to_client => localize("Missing market data for exit spot."),
            });
        }
        if (not $self->expiry_daily and $underlying->intradays_must_be_same_day and $exchange->trading_days_between($first_date, $last_date)) {
            $self->add_errors({
                severity => 99,
                alert    => 1,
                message  => 'Exit tick date ['
                    . $last_date->datetime
                    . '] differs from entry tick date ['
                    . $first_date->datetime
                    . '] on intraday contract for '
                    . $underlying->symbol,
                message_to_client => localize("Intraday contracts may not cross market open."),
            });
        }
        if ($self->tick_expiry) {
            my $actual_duration = Time::Duration::Concise->new(interval => $last_date->epoch - $first_date->epoch);
            if ($actual_duration->seconds > $self->max_tick_expiry_duration->seconds) {
                $self->add_errors({
                    severity => 100,
                    alert    => 1,
                    message  => 'Tick expiry duration ['
                        . $actual_duration->normalized_code
                        . '] exceeds permitted maximum ['
                        . $self->max_tick_expiry_duration->normalized_code . '] on '
                        . $underlying->symbol,
                    message_to_client => localize("Missing market data for contract period."),
                });
            }
        }
    }

    return $exit_tick;
}

sub _has_ticks_before_close {
    my ($self, $closing) = @_;

    my $underlying = $self->underlying;

    my $closing_tick = $underlying->tick_at($closing->epoch, {allow_inconsistent => 1});

    return (defined $closing_tick and $closing->epoch - $closing_tick->epoch > $underlying->max_suspend_trading_feed_delay->seconds) ? 0 : 1;
}

1;

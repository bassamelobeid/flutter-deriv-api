package BOM::MT5::Utility::CircuitBreaker;

=head1 NAME

BOM::MT5::Utility::CircuitBreaker

=head1 DESCRIPTION

A helper module to implement a circuit breaker pattern on MT5 requests

=cut

use strict;
use warnings;

use BOM::Config::Redis;

use constant {
    FAILURE_THRESHOLD              => 20,
    RETRY_AFTER                    => 30,
    FAILURE_COUNT_KEY_TEMPLATE     => 'system.mt5.%s_%s.connection_fail_count',
    LAST_FAILURE_TIME_KEY_TEMPLATE => 'system.mt5.%s_%s.last_failure_time',
    TESTING_KEY_TEMPLATE           => 'system.mt5.%s_%s.connection_test',
    TESTING_KEY_TTL                => 60,
    REDIS_KEY_TTL                  => 3600,
};

=head2 new

A constructor subroutine returns a new instance of this module

=over 4

=item * C<server_type> - MT5 server type (demo, real)
=item * C<server_code> - MT5 server code (e.g 01)

=back

=cut

sub new {
    my ($class, %args) = @_;

    die "The type or the code of the MT5 server is missing" unless $args{server_type} && $args{server_code};

    my $server_type = $args{server_type};
    my $server_code = $args{server_code};

    my $self = {
        failure_count_key     => sprintf(FAILURE_COUNT_KEY_TEMPLATE,     $server_type, $server_code),
        last_failure_time_key => sprintf(LAST_FAILURE_TIME_KEY_TEMPLATE, $server_type, $server_code),
        testing_key           => sprintf(TESTING_KEY_TEMPLATE,           $server_type, $server_code),
    };

    return bless $self, $class;
}

=head2 _is_circuit_open

Circuit status is open when:

=over 4

=item * The failure counter exceeds the failure threshold
=item * The difference between the current time and the last failure time less than the time period to retry

=back

The requests are not allowed when the circuit status is open.
Returns 1 if the circuit status is open and 0 otherwise.

=cut

sub _is_circuit_open {
    my $self       = shift;
    my $redis_keys = $self->_get_keys_value();
    return $redis_keys->{failure_count} > FAILURE_THRESHOLD && (time - $redis_keys->{last_failure_time}) < RETRY_AFTER;
}

=head2 _is_circuit_half_open

Circuit status is half-open when:

=over 4

=item * The failure counter exceeds the failure threshold
=item * The difference between the current time and the last failure time more than the time period to retry

=back

Just the test request is allowed when the circuit status is half-open.
Returns 1 if the circuit status is half-open and 0 otherwise.

=cut

sub _is_circuit_half_open {
    my $self       = shift;
    my $redis_keys = $self->_get_keys_value();
    return $redis_keys->{failure_count} > FAILURE_THRESHOLD && (time - $redis_keys->{last_failure_time}) > RETRY_AFTER;
}

=head2 _is_circuit_closed

Circuit status is closed when:

=over 4

=item * The failure counter has not exceeded the failure threshold

=back

The requests are allowed when the circuit status is closed.
Returns 1 if the circuit status is closed and 0 otherwise.

=cut

sub _is_circuit_closed {
    my $self          = shift;
    my $failure_count = $self->_get_keys_value()->{failure_count};
    return $failure_count <= FAILURE_THRESHOLD;
}

=head2 request_state

Check the circuit status and return a hash reference contain:

=over 4

=item * C<allowed> - 1 if the request is allowed or 0 otherwise
=item * C<testing> - 1 if it's a test request or 0 otherwise

=back

=cut

sub request_state {
    my $self = shift;

    return {
        allowed => 0,
        testing => 0,
    } if $self->_is_circuit_open;

    if ($self->_is_circuit_half_open) {
        my $is_testing_set = $self->_set_testing();
        return {
            allowed => 1,
            testing => 1,
        } if $is_testing_set;
        return {
            allowed => 0,
            testing => 0,
        };
    }

    return {
        allowed => 1,
        testing => 0,
    };
}

=head2 circuit_reset

Delete the keys of the failure counter, the last failure time and the testing, this mean close the circuit

=cut

sub circuit_reset {
    my $self        = shift;
    my $redis_write = BOM::Config::Redis::redis_mt5_user_write();
    $redis_write->del($self->{failure_count_key}, $self->{last_failure_time_key}, $self->{testing_key});
}

=head2 record_failure

Increment failure counter one and update the last failure time with the current time

=cut

sub record_failure {
    my $self        = shift;
    my $redis_write = BOM::Config::Redis::redis_mt5_user_write();

    $redis_write->incr($self->{failure_count_key});
    $redis_write->expire($self->{failure_count_key}, REDIS_KEY_TTL);
    $redis_write->set(
        $self->{last_failure_time_key} => time,
        EX                             => REDIS_KEY_TTL,
    );

    # Remove the testing flag in case the failure request was a testing request.
    # So we will be able to perform another testing request when the circuit status back to half-open
    $redis_write->del($self->{testing_key});

}

=head2 _set_testing

Set the testing flag, which means we have performed a test request.
Returns 1 if set successfully or 0 otherwise.

=cut

sub _set_testing {
    my $self        = shift;
    my $redis_write = BOM::Config::Redis::redis_mt5_user_write();
    return 0 if not $redis_write->set($self->{testing_key}, 1, 'NX', 'EX', TESTING_KEY_TTL);
    return 1;
}

=head2 _get_keys_value

Return a hash reference contain the failure counter and the last failure time.

=cut

sub _get_keys_value {
    my $self       = shift;
    my $redis_read = BOM::Config::Redis::redis_mt5_user();
    return {
        failure_count     => $redis_read->get($self->{failure_count_key})     // 0,
        last_failure_time => $redis_read->get($self->{last_failure_time_key}) // 0
    };
}

1;

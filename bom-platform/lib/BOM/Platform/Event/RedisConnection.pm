package BOM::Platform::Event::RedisConnection;

use strict;
use warnings;

use RedisDB;
use Syntax::Keyword::Try;
use BOM::Config;

use constant TIMEOUT => 5;    # seconds

my $connections = {};

use parent 'Exporter';
our @EXPORT_OK = qw(_write_connection _read_connection);

=head1 NAME

BOM::Platform::Event::RedisConnection - Redis connection management for event handling

=head1 SYNOPSIS

    use BOM::Platform::Event::RedisConnection qw(_write_connection _read_connection);

    my $write_conn = _write_connection();
    my $read_conn  = _read_connection();

=head1 DESCRIPTION

This module provides methods for managing Redis connections for writing and reading events. It maintains a connection pool and ensures that the connections are valid before using them.

=head1 CONSTANTS

=head2 TIMEOUT

The timeout value (in seconds) for Redis connections.

=cut

=head1 METHODS

=head2 _write_connection

  _write_connection()

Returns a Redis connection for writing. It checks if an existing connection is valid and reuses it if possible; otherwise, it creates a new connection.

=head3 Return value

Returns a RedisDB object for writing.

=cut

sub _write_connection {
    if ($connections->{write}) {
        try {
            $connections->{write}->ping();
        } catch {
            $connections->{write} = undef;
        }
    }

    return _get_connection_by_type('write');
}

=head2 _read_connection

  _read_connection()

Returns a Redis connection for reading. It creates a new connection if one does not already exist.

=head3 Return value

Returns a RedisDB object for reading.

=cut

sub _read_connection {
    return _get_connection_by_type('read');
}

=head2 _get_connection_by_type

  _get_connection_by_type($type)

Returns a Redis connection based on the specified type ('write' or 'read'). It reads the configuration from BOM::Config and creates a new connection if one does not already exist.

=head3 Parameters

=over 4

=item * C<$type> - The type of connection ('write' or 'read').

=back

=head3 Return value

Returns a RedisDB object based on the specified type.

=cut

sub _get_connection_by_type {
    my $type = shift;

    my $config = BOM::Config::redis_events_config();

    $connections->{$type} //= RedisDB->new(
        timeout => TIMEOUT,
        host    => $config->{$type}->{host},
        port    => $config->{$type}->{port},
        ($config->{$type}->{password} ? (password => $config->{$type}->{password}) : ()));

    return $connections->{$type};
}

1;

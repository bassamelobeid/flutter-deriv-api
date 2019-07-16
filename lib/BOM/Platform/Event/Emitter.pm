package BOM::Platform::Event::Emitter;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use RedisDB;
use Try::Tiny;
use YAML::XS qw(LoadFile);

=head1 NAME

BOM::Platform::Event::Emitter - Emitter events to storage

=head1 SYNOPSIS

    # emit an event
    BOM::Platform::Event::Emitter::emit('emit_details', {
        loginid => 'CR123',
        email   => 'abc@binary.com',
    });

    # get emit event
    BOM::Platform::Event::Emitter::get()

=head1 DESCRIPTION

This class is generic event emit class, as of now underlying mechanism
use redis to store events as FIFO queue

=cut

use constant TIMEOUT => 5;

my %event_queue_mapping = (
    email_statement          => 'STATEMENTS_QUEUE',
    document_upload          => 'DOCUMENT_AUTHENTICATION_QUEUE',
    ready_for_authentication => 'DOCUMENT_AUTHENTICATION_QUEUE',
    client_verification      => 'DOCUMENT_AUTHENTICATION_QUEUE'
);

my $config = LoadFile($ENV{BOM_TEST_REDIS_EVENTS} // '/etc/rmg/redis-events.yml');

my $connections = {};

=head1 METHODS

=head2 emit

Given type and data corresponding for an event, it stores that event

=head3 Required parameters

=over 4

=item * type : type of event to be emitted

=item * data : data for event to be emitted

=back

=head3 Return value

=over 4

Positive number on successful emit of event, zero otherwise

=back

=cut

sub emit {
    my ($type, $data) = @_;

    die "Missing required parameter: type." unless $type;
    die "Missing required parameter: data." unless $data;

    my $event_data;
    try {
        $event_data = encode_json_utf8({
            type    => $type,
            details => $data
        });
    }
    catch {
        die "Invalid data format: cannot convert to json";
    };

    if ($event_data) {
        my $queue_name = _queue_name($type);
        my $queue_size = _write_connection()->lpush($queue_name, $event_data);
        stats_gauge(lc "$queue_name.size", $queue_size) if $queue_size;
        return $queue_size;
    }

    return 0;
}

=head2 get

Get emitted event

=head3 Return value

=over 4

If any event is present then return an event object as hash else return undef

Event hash is in form of:

    {type => 'emit_details', details => { loginid => 'CR123', email => 'abc@binary.com' }}

=back

=cut

sub get {
    my $queue_name = shift;

    my $event_data = _write_connection()->brpop($queue_name, 1);

    my $decoded_data;

    if ($event_data) {
        try {
            $decoded_data = decode_json_utf8($event_data->[1]);
            stats_inc(lc "$queue_name.read");
        }
        catch {
            stats_inc(lc "$queue_name.invalid_data");
        };
    }

    return $decoded_data;
}

sub _write_connection {
    if ($connections->{write}) {
        try {
            $connections->{write}->ping();
        }
        catch {
            $connections->{write} = undef;
        };
    }

    return _get_connection_by_type('write');
}

sub _read_connection {
    return _get_connection_by_type('read');
}

sub _get_connection_by_type {
    my $type = shift;

    $connections->{$type} //= RedisDB->new(
        timeout => TIMEOUT,
        host    => $config->{$type}->{host},
        port    => $config->{$type}->{port},
        ($config->{$type}->{password} ? (password => $config->{$type}->{password}) : ()));

    return $connections->{$type};
}

=head2 get

Bind event name to its queue

=head3 Return function name

=over 4

=cut

sub _queue_name {
    return $event_queue_mapping{+shift} // 'GENERIC_EVENTS_QUEUE';
}

1;

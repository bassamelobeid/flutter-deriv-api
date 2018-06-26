package BOM::Platform::Event::Register;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use RedisDB;
use Try::Tiny;
use YAML::XS qw(LoadFile);

=head1 NAME

BOM::Platform::Event::Register - Register events to storage

=head1 SYNOPSIS

    # register an event
    BOM::Platform::Event::Register::register('register_details', {
        loginid => 'CR123',
        email   => 'abc@binary.com',
    });

    # get registered event
    BOM::Platform::Event::Register::get()

=head1 DESCRIPTION

This class is generic event register class, as of now underlying mechanism
use redis to store events as FIFO queue

=cut

use constant TIMEOUT    => 5;
use constant QUEUE_NAME => 'GENERIC_EVENTS_QUEUE';

my $config = LoadFile($ENV{BINARY_EVENT_REDIS_CONFIG} // '/etc/rmg/ws-redis.yml');
my $connections = {};

=head1 METHODS

=head2 register

Given type and data corresponding for an event, it stores that event

=head3 Required parameters

=over 4

=item * type : type of event to be registered

=item * data : data for event to be registered

=back

=head3 Return value

=over 4

Positive number on successful register of event, zero otherwise

=back

=cut

sub register {
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
        my $queue_size = _write_connection()->lpush(QUEUE_NAME, $event_data);
        stats_gauge('generic_event.queue.size', $queue_size) if $queue_size;
        return $queue_size;
    }

    return 0;
}

=head2 get

Get registered event

=head3 Return value

=over 4

If any event is present then return an event object as hash else return undef

Event hash is in form of:

    {type => 'register_details', details => { loginid => 'CR123', email => 'abc@binary.com' }}

=back

=cut

sub get {
    my $event_data = _read_connection()->brpop(QUEUE_NAME, 1);
    my $decoded_data;

    if ($event_data) {
        try {
            $decoded_data = decode_json_utf8($event_data->[1]);
            stats_inc('generic_event.queue.read');
        }
        catch {
            stats_inc('generic_event.queue.invalid_data');
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

1;

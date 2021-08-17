package BOM::Platform::Event::Emitter;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);
use RedisDB;
use Syntax::Keyword::Try;
use YAML::XS qw(LoadFile);

use BOM::Platform::Context qw(request);

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
use redis to store events as stream

=cut

use constant TIMEOUT => 5;

my %event_stream_mapping = (
    email_statement                 => 'STATEMENTS_STREAM',
    document_upload                 => 'DOCUMENT_AUTHENTICATION_STREAM',
    ready_for_authentication        => 'DOCUMENT_AUTHENTICATION_STREAM',
    client_verification             => 'DOCUMENT_AUTHENTICATION_STREAM',
    onfido_doc_ready_for_upload     => 'DOCUMENT_AUTHENTICATION_STREAM',
    identity_verification_requested => 'DOCUMENT_AUTHENTICATION_STREAM',
    affiliate_sync_initiated        => 'AFFILIATE_SYNC_LONG_RUNNING_STREAM',
    crypto_subscription             => 'CRYPTO_EVENTS_STREAM',
    fraud_address                   => 'CRYPTO_EVENTS_STREAM',
    new_crypto_address              => 'CRYPTO_EVENTS_STREAM',
    client_promo_codes_upload       => 'PROMO_CODE_IMPORT_LONG_RUNNING_STREAM',
    anonymize_client                => 'ANONYMIZATION_STREAM',
    bulk_anonymization              => 'ANONYMIZATION_STREAM',
    multiplier_hit_type             => 'CONTRACT_STREAM',
    bulk_authentication             => 'BULK_EVENTS_STREAM',
    # We want to move these events out of general queue, without creating a new service.
    # ANONYMIZATION_QUEUE can be renamed to avoid confusion.
    mt5_inactive_account_closed => 'ANONYMIZATION_STREAM',
    mt5_inactive_notification   => 'ANONYMIZATION_STREAM',
);

my $config = LoadFile('/etc/rmg/redis-events.yml');

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

True on successful emit of event, False otherwise

=back

=cut

sub emit {
    my ($type, $data) = @_;

    die "Missing required parameter: type." unless $type;
    die "Missing required parameter: data." unless $data;

    my $request      = request();
    my $context_info = {
        brand_name => $request->brand->name,
        language   => $request->language,
        app_id     => $request->app_id,
    };

    my $event_data;
    try {
        $event_data = encode_json_utf8({
            type    => $type,
            details => $data,
            context => $context_info,
        });
    } catch {
        die "Invalid data format: cannot convert to json";
    }

    if ($event_data) {
        my $stream_name = _stream_name($type);
        _write_connection()->execute(XADD => ($stream_name, qw(MAXLEN ~ 100000), '*', 'event', $event_data));

        # Metrics to log emitted events tagged by event type and queue name
        stats_inc(lc "event_emitter.sent", {tags => ["type:$type", "queue:$stream_name"]});

        return 1;
    }

    return 0;
}

=head2 get (deprecated)

Get emitted event (This is a deprecated subroutine and should not be used in new code)

=head3 Return value

=over 4

If any event is present then return an event object as hash else return undef

Event hash is in form of:

    {type => 'emit_details', details => { loginid => 'CR123', email => 'abc@binary.com' }, context => { language => 'EN', brand_name => 'deriv', app_id => '' }}

=back

=cut

sub get {
    my $stream_name = shift;

    my $event_data = _write_connection()->execute(XRANGE => ($stream_name, '-', '+', 'COUNT', 1));

    my $decoded_data;

    if ($event_data->[0]) {
        try {
            $decoded_data = decode_json_utf8($event_data->[0]->[1]->[1]);
            stats_inc(lc "$stream_name.read");
        } catch {
            stats_inc(lc "$stream_name.invalid_data");
        }
    }

    return $decoded_data;
}

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

=head2 _stream_name

Bind event name to its stream

=head3 Return function name

=cut

sub _stream_name {
    return $event_stream_mapping{+shift} // 'GENERIC_EVENTS_STREAM';
}

1;

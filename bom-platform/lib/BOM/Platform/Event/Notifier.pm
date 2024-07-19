package BOM::Platform::Event::Notifier;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_inc);
use JSON::MaybeXS;
use Log::Any qw($log);
use RedisDB;
use Syntax::Keyword::Try;

use BOM::Platform::Event::RedisConnection qw(_write_connection);

=head1 NAME

BOM::Platform::Event::Notifier - Notify events to storage

=head1 SYNOPSIS

    # Add a notification event for user
    BOM::Platform::Event::Notifier::notify_add({
        binary_user_id => $client->binary_user_id,
        message_id => 'financial-assessment-notification',
        payload => {"key" => "value"}, # optional
        source_id => 'abc123',        # optional
        category => 'act',
    });

    # Delete a notification event for user
    BOM::Platform::Event::Notifier::notify_delete({
        binary_user_id => $client->binary_user_id,
        message_id => 'financial-assessment-notification',
        source_id => 'abc123' # optional
    });

=head1 DESCRIPTION

This class is designed to emit notification events. The underlying mechanism uses Redis to store events in a stream. The notifications can be used to trigger various actions in the system, identified by different categories and operations.

=head1 CONSTANTS

=head2 STREAM_NAME

The name of the Redis stream where events are stored.

=head2 MAX_PAYLOAD_LENGTH

The maximum allowed length for the payload data (json string).

=head2 MAX_SOURCE_ID_LENGTH

The maximum allowed length for the source ID.

=cut

use constant STREAM_NAME          => 'NOTIFICATIONS::EVENTS';
use constant MAX_PAYLOAD_LENGTH   => 2048;
use constant MAX_SOURCE_ID_LENGTH => 50;

=head1 METHODS

=head2 notify_add

  notify_add($event);

Adds a new event notification. The C<$event> parameter should be a hash reference with the necessary keys.

=head3 Parameters

=over 4

=item * C<$event> -  hash reference with the required params.

=back

=head3 Returns

C<1> Return 1 on success (notification added to redis-events). Dies on failure.

=cut

sub notify_add {
    my ($event) = @_;

    $event->{operation} = 'add';
    return _notify($event);
}

=head2 notify_delete

  notify_delete($event);

Adds a new event notification to remove at the service. The C<$event> parameter should be a hash reference with the necessary keys.

=head3 Parameters

=over 4

=item * C<$event> -  hash reference with the required params.

=back

=head3 Returns

C<1> Return 1 on success (notification added to redis-events). Dies on failure.

=cut

sub notify_delete {
    my ($event) = @_;
    $event->{operation} = 'delete';
    return _notify($event);
}

=head2 _notify

  _notify($event);

Sends a notification event. The C<$event> parameter should be a hash reference with the following keys:

=head3 Parameters

=over 4

=item * C<operation> - The operation to perform ('add' or 'delete').

=item * C<message_id> - The message ID (required). This ID is used by the frontend to identify the event and select the appropriate template.

=item * C<binary_user_id> - The binary user ID (required).

=item * C<category> - The category of the event ('act' or 'see'). Mandatory when adding a notification.

=item * C<source_id> - The source ID of the event. This identifies the source of the event, useful if they are not unique. (optional, maximum length 50)

=item * C<payload> - The payload data. This needs to be a hash or empty value (maximum length 2048).

=back

This method handles the validation, processing, and sending of the notification event to the Redis stream. It also logs metrics related to the event notification.

=cut

sub _notify {
    my ($event) = @_;

    validate_params($event);

    my $operation  = $event->{operation};
    my $message_id = $event->{message_id};

    $event->{payload} = _validate_and_stringify_payload($event->{payload});

    #print($event->{payload});

    # Send notification event to Redis
    _write_connection()->execute(
        XADD => (
            STREAM_NAME,               qw(MAXLEN ~ 100000), '*',                      'operation',
            $event->{operation},       'binary_user_id',    $event->{binary_user_id}, 'category',
            $event->{category},        'message_id',        $event->{message_id},     'source_id',
            $event->{source_id} // '', 'payload',           $event->{payload} // ''
        ));

    # Log metrics
    stats_inc(lc "notify_emitter.sent", {tags => ["operation:$operation", "message_id:$message_id", "queue:" . STREAM_NAME]});

    return 1;
}

=head2 validate_params

  validate_params($event);

Validates the parameters of the event notification. This method ensures that all required fields are present and that their values are within the allowed constraints.

=head3 Parameters

=over 4

=item * C<$event> -  hash reference with the required params.

=back

=head3 Returns

C<1> Return 1 on success. Dies on failure.

=cut

sub validate_params {
    my ($event) = @_;

    die "Missing required parameter: message_id."     unless $event->{message_id};
    die "Missing required parameter: binary_user_id." unless $event->{binary_user_id};
    die "Invalid value for parameter: operation."     unless $event->{operation} eq 'add' || $event->{operation} eq 'delete';
    die "length of source_id exceeded MAX_SOURCE_ID_SIZE: " . MAX_SOURCE_ID_LENGTH if length($event->{source_id} // '') > MAX_SOURCE_ID_LENGTH;

    if ($event->{operation} eq 'add') {
        die "Missing required parameter: category."                              unless $event->{category};
        die "Invalid value for parameter: category. Should be one of: act, see." unless $event->{category} eq 'act' || $event->{category} eq 'see';
    }

    return 1;
}

=head2 _validate_and_stringify_payload

This function takes a payload, checks if it exists, and attempts to convert it to a JSON string using the `encode_json` function from the `JSON` module. If the conversion fails, it throws an error.

=head3 Parameters

=over 4

=item *

C<$payload> - A reference to the payload that needs to be converted to a JSON string. This should be a valid Perl data structure (hash).

=back

=head3 Returns

A JSON string representation of the payload if the conversion is successful. Dies on failure

=cut

sub _validate_and_stringify_payload {
    my ($payload) = @_;

    if ($payload) {
        die "Invalid JSON payload" if ref $payload ne 'HASH';
        try {
            my $payload_str = encode_json($payload);
            die "length of payload exceeded MAX_PAYLOAD_SIZE: " . MAX_PAYLOAD_LENGTH if length($payload_str) > MAX_PAYLOAD_LENGTH;
            return $payload_str;
        } catch ($e) {
            die "Failed to encode payload to JSON: $e";
        };
    }
}
1;

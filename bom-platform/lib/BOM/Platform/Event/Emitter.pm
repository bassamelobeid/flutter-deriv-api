package BOM::Platform::Event::Emitter;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use JSON::MaybeUTF8            qw(:v1);
use Log::Any                   qw($log);
use RedisDB;
use Syntax::Keyword::Try;
use BOM::Config;
use BOM::Platform::Event::RedisConnection qw(_write_connection _read_connection);

use BOM::Platform::Context qw(request);
use Log::Any               qw($log);

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
    email_statement                     => 'STATEMENTS_STREAM',
    document_upload                     => 'DOCUMENT_AUTHENTICATION_STREAM',
    ready_for_authentication            => 'DOCUMENT_AUTHENTICATION_STREAM',
    client_verification                 => 'DOCUMENT_AUTHENTICATION_STREAM',
    onfido_doc_ready_for_upload         => 'DOCUMENT_AUTHENTICATION_STREAM',
    identity_verification_requested     => 'DOCUMENT_AUTHENTICATION_STREAM',
    idv_dynamic_settings_updated        => 'DOCUMENT_AUTHENTICATION_STREAM',
    affiliate_sync_initiated            => 'AFFILIATE_SYNC_LONG_RUNNING_STREAM',
    crypto_notify_external_deposit      => 'CRYPTO_EVENTS_STREAM',
    crypto_notify_external_withdrawal   => 'CRYPTO_EVENTS_STREAM',
    client_promo_codes_upload           => 'PROMO_CODE_IMPORT_LONG_RUNNING_STREAM',
    anonymize_client                    => 'ANONYMIZATION_STREAM',
    auto_anonymize_candidates           => 'ANONYMIZATION_STREAM',
    bulk_anonymization                  => 'BULK_ANONYMIZATION_STREAM',
    anonymize_clients                   => 'BULK_ANONYMIZATION_STREAM',
    multiplier_hit_type                 => 'CONTRACT_STREAM',
    multiplier_near_expire_notification => 'CONTRACT_STREAM',
    multiplier_near_dc_notification     => 'CONTRACT_STREAM',
    bulk_authentication                 => 'BULK_EVENTS_STREAM',
    bulk_client_status_update           => 'BULK_EVENTS_STREAM',
    mt5_inactive_account_closed         => 'BULK_EVENTS_STREAM',
    mt5_inactive_notification           => 'BULK_EVENTS_STREAM',
    derivx_account_deactivated          => 'BULK_EVENTS_STREAM',
    affiliate_loginids_sync             => 'AFFILIATE_SYNC_LONG_RUNNING_STREAM',
    derivez_inactive_account_closed     => 'BULK_EVENTS_STREAM',
    derivez_inactive_notification       => 'BULK_EVENTS_STREAM',
    onfido_check_completed              => 'DOCUMENT_AUTHENTICATION_STREAM',
    monolith_hello                      => 'NODEJS_STREAM',
    idv_configuration                   => 'NODEJS_STREAM',
    idv_webhook                         => 'NODEJS_STREAM',
    idv_verification                    => 'NODEJS_STREAM',
    dynamic_works_binary_trade          => 'DYNAMIC_WORKS_BINARY_OPTIONS_STREAM',
    dynamic_works_cfd_trade             => 'DYNAMIC_WORKS_CFD_STREAM',
);

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
    my ($type, $data, $event) = @_;

    die "Missing required parameter: type." unless $type;
    die "Missing required parameter: data." unless $data;

    my $request      = request();
    my $context_info = {
        brand_name => $request->brand->name,
        language   => $request->language,
        app_id     => $request->app_id,
    };
    $event = ($event // '') eq '' ? 'event' : $event;
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
        _write_connection()->execute(XADD => ($stream_name, qw(MAXLEN ~ 100000), '*', $event // 'event', $event_data));

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

=head2 _stream_name

Bind event name to its stream

=head3 Return function name

=cut

sub _stream_name {
    return $event_stream_mapping{+shift} // 'GENERIC_EVENTS_STREAM';
}

=head2 is_transfer_blocked

Checks if transfers are temporarily blocked at the client level.

=head3 Parameters

=over 4

=item * C<$login_id> - The login ID of the client.

=back

=head3 Returns

C<1> if transfers are blocked, C<0> if the block does not exist or has expired.

=cut

sub is_transfer_blocked {
    my $login_id = shift;

    # Redis key for client-level transfer block
    my $lock_key = "TRANSFER::BLOCKED::$login_id";

    my $lock_exists = _read_connection->exists($lock_key);
    return $lock_exists ? 1 : 0;
}

=head2 block_transfer_temporarily

Blocks transfers temporarily at the client level.

=head3 Parameters

=over 4

=item * C<$login_id> - The login ID of the client.

=back

=head3 Returns

C<1> if the transfer blocking was successful, C<0> if the lock already exists, and C<-1> if an error occurred.

=cut

sub block_transfer_temporarily {
    my $login_id = shift;

    if (is_transfer_blocked($login_id)) {
        $log->info("Transfer block already exists for client with login ID: $login_id");
        return 0;
    }

    # Redis key for client-level transfer block
    my $lock_key = "TRANSFER::BLOCKED::$login_id";

    # Set the lock with an expiration time of 5 minutes (300 seconds)
    my $lock_acquired = _write_connection->setex($lock_key, 300, 1);

    if ($lock_acquired) {
        $log->info("Transfer blocked temporarily for client with login ID: $login_id");
        return 1;
    } else {
        $log->error("Failed to block transfer temporarily for client with login ID: $login_id");
        return -1;
    }
}

=head2 block_account_migration

Blocks account migration temporarily at the client level.

=head3 Parameters

=over 4

=item * C<$binary_user_id> - The User ID of the client.

=item * C<$account_type> - The account type of the client.

=back

=head3 Returns

C<1> if the account migration blocking was successful, C<0> if the lock already exists, and C<-1> if an error occurred.

=cut

sub block_account_migration {

    my $params = shift;
    my ($binary_user_id, $account_type) = ($params->{binary_user_id}, $params->{account_type});
    if (not(defined $binary_user_id and defined $account_type)) {
        $log->errorf("Failed to block account migration for client with undefined User ID or account type");
        return -1;
    }

    try {
        my $yaml_config = BOM::Config::redis_mt5_user_config()->{write};
        my $mt5_redis   = RedisDB->new(
            uri  => "redis://" . $yaml_config->{host} . ":" . $yaml_config->{port},
            auth => $yaml_config->{password},
        );

        my $migration_key = $account_type . '_MIGRATION_IN_PROGRESS::' . $binary_user_id;
        return 0 if $mt5_redis->execute('get', $migration_key);

        $mt5_redis->execute('set', $migration_key, 1, 'EX', 180);
        return 1;

    } catch ($e) {
        $log->errorf("Failed to block %s account migration for client with User ID: %s", $account_type, $binary_user_id);
        return -1;
    }
}

1;

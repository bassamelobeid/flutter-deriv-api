#!/etc/rmg/bin/perl
use strict;
use warnings;

use Digest::SHA qw(sha1_hex);
use JSON::XS;
use Path::Tiny;
use List::MoreUtils               qw(uniq);
use Encode                        qw(decode_utf8 encode_utf8);
use DataDog::DogStatsd::Helper    qw(stats_inc);
use Binary::WebSocketAPI::Actions qw(actions_config);
use Binary::WebSocketAPI::v3::Instance::Redis 'redis_rpc';

use constant {
    LOCK_REDIS_KEY         => 'SCHEMA_UPDATE::LOCK',
    DATADOG_PREFIX         => 'schema_update',
    SCHEMA_PATH            => '/home/git/regentmarkets/binary-websocket-api/config/v3',
    SCHEMA_NAME_SPACE      => 'SCHEMA',
    MONOLITH_NAME_SPACE    => 'BOM',
    SCHEMA_UPDATES_CHANNEL => 'SCHEMA::NOTIFICATION',
};

=encoding utf-8

=head1 NAME

schema_updater


=head1 DESCRIPTION

This scipt allow to publish updated schema configuration to redis and send notification to WS about schema changes.

=cut

my $json = JSON::XS->new;
$json->canonical(1);

run();

sub run {
    my $redis = redis_rpc();

    # Avoid duplicate run of this script.
    my $lock = $redis->set(LOCK_REDIS_KEY, 1, 'NX', EX => 60);
    return unless $lock;

    my $available_actions = actions_update($redis);

    clean_removed_actions($redis, $available_actions);

    #release lock
    $redis->del(LOCK_REDIS_KEY);
}

sub actions_update {
    my ($redis) = @_;

    my %action_index;

    my $priority = 1;
    for my $action_data (read_actions()->@*) {

        my ($action_name, $action_cfg) = $action_data->@*;
        $action_cfg //= +{};

        $action_index{$action_name} = 1;

        my $cfg = +{};

        my $send_data    = decode_utf8(path(SCHEMA_PATH . "/$action_name/send.json")->slurp);
        my $receive_data = decode_utf8(path(SCHEMA_PATH . "/$action_name/receive.json")->slurp);

        my $send_schema = $json->decode($send_data);

        $cfg->{stash_params} = $action_cfg->{stash_params} // [];

        push @{$cfg->{stash_params}}, qw( language country_code );
        push @{$cfg->{stash_params}}, 'token'
            if $send_schema->{auth_required};

        my @unique = uniq @{$cfg->{stash_params}};
        $cfg->{stash_params} = \@unique;

        $cfg->{category} = $action_cfg->{category} // '';
        $cfg->{priority} = $priority++;

        my $cfg_data = encode_utf8($json->encode($cfg));

        my $ver = sha1_hex(join q{} => (encode_utf8($send_data), encode_utf8($receive_data), $cfg_data));

        my $cur_ver = $redis->hget(get_redis_key($action_name), 'VERSION') // '';
        next if $cur_ver eq $ver;

        my $event_type = $cur_ver ? 'action_updated' : 'action_added';

        my $txn = $redis->multi;

        $txn->hset(
            get_redis_key($action_name),
            'VERSION' => $ver,
            'SEND'    => encode_utf8($send_data),
            'RECEIVE' => encode_utf8($receive_data),
            'CONFIG'  => encode_json($cfg),
        );

        $txn->_execute(
            pubsub => 'publish',
            SCHEMA_UPDATES_CHANNEL,
            $json->encode(
                +{
                    type => $event_type,
                    data => {
                        name    => $action_name,
                        version => $ver
                    }}));

        $txn->exec;

        # Add stats to datadog on the update
        stats_inc(DATADOG_PREFIX, {tags => ["action:$action_name", "event_type:$event_type"]});
    }

    return \%action_index;
}

sub clean_removed_actions {
    my ($redis, $available_actions) = @_;

    my $schema_namespace = get_redis_key('');
    my $keys             = $redis->keys($schema_namespace . '*');
    for my $key ($keys->@*) {
        my ($action_name) = $key =~ m/^\Q$schema_namespace\E(.+)$/;

        unless ($action_name) {
            warn "Unable to extract action name from key $key";
            next;
        }

        # Action is available in configuration.
        next if $available_actions->{$action_name};

        my $txn = $redis->multi;

        $txn->del($key);

        $txn->_execute(
            pubsub => 'publish',
            SCHEMA_UPDATES_CHANNEL,
            encode_json(
                +{
                    type => 'action_removed',
                    data => {name => $action_name}}));

        $txn->exec;

        # Add stats to datadog on the delete
        stats_inc(DATADOG_PREFIX, {tags => ["action:$action_name", "event_type:action_deleted"]});
    }
}

sub get_redis_key {
    my ($action) = @_;
    return join q{::} => (SCHEMA_NAME_SPACE, MONOLITH_NAME_SPACE, $action);
}

sub read_actions {

    # In future we'll move list of actions to yml configuration
    return Binary::WebSocketAPI::Actions->actions_config;
}

exit 0;

package BOM::Pricing::PriceDaemon;

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw/stats_histogram stats_inc stats_count stats_timing/;
use Encode;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use JSON::MaybeUTF8 qw(:v1);
use List::Util qw(first);
use Time::HiRes ();
use Try::Tiny;
use Data::Dumper;

use BOM::MarketData qw(create_underlying);
use BOM::Platform::Context;
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Pricing::v3::Contract;
use Volatility::LinearCache;
#TODO DEBUG CODE, SHOULD BE RMMOVED
use Devel::Confess;
# DEBUG CODE END

use constant {
    DURATION_DONT_PRICE_SAME_SPOT => 10,
};

sub new { return bless {@_[1 .. $#_]}, $_[0] }

=head2 is_running

Returns true if running, false if not.

=cut

sub is_running {
    return shift->{is_running};
}

=head2 stop

Stops the loop after the current price.

=cut

sub stop {
    shift->{is_running} = 0;
    return;
}

my $commands = {
    proposal => {
        required_params => [qw(contract_type currency symbol)],
        get_underlying  => \&_get_underlying_price,
        process         => \&_process_price,
    },
    proposal_open_contract => {
        required_params => [qw(contract_id short_code currency landing_company)],
        get_underlying  => \&_get_underlying_bid,
        process         => \&_process_bid,
    },
    proposal_array_item => {
        required_params => [qw(contract_type currency symbol)],
        get_underlying  => \&_get_underlying_price,
        process         => \&_process_price,
    },

};

#TODO remove following lines
# these line is for back-compatible
# should be removed after the PR https://github.com/regentmarkets/binary-websocket-api/pull/2408 released to the production server.
$commands->{price} = $commands->{proposal};
$commands->{bid}   = $commands->{proposal_open_contract};
#TODO end
my $eco_snapshot = 0;

sub process_job {
    my ($self, $redis, $next, $params) = @_;

    my $cmd          = $params->{price_daemon_cmd};
    my $current_time = time;

    my $underlying           = $self->_get_underlying_or_log($next, $params) or return undef;
    my $current_spot_ts      = $underlying->spot_tick->epoch;
    my $last_priced_contract = eval { decode_json_utf8($redis->get($next) // die 'default') } || {time => 0};
    my $last_price_ts        = $last_priced_contract->{time};

    # For plain queue, if we have request for a price, and tick has not changed since last one, and it was not more
    # than 10 seconds ago - just ignore it.
    if (    $current_spot_ts == $last_price_ts
        and $current_time - $last_price_ts <= DURATION_DONT_PRICE_SAME_SPOT)
    {
        stats_inc("pricer_daemon.skipped_duplicate_spot", {tags => $self->tags});
        return undef;
    }

    my $r = BOM::Platform::Context::Request->new({language => $params->{language} // 'EN'});
    BOM::Platform::Context::request($r);

    my $response = $commands->{$cmd}->{process}->($self, $params);

    $response->{price_daemon_cmd} = $cmd;
    # contract parameters are stored after first call, no need to send them with every stream message
    delete $response->{contract_parameters};

    # when it reaches here, contract is considered priced.
    $redis->set(
        $next => encode_json_utf8({
                # - for proposal open contract, don't use $current_time here since we are using this time to check if we want to skip repricing contract with the same spot price.
                # - for proposal, because $response doesn't have current_spot_time, we will resort to $current_time
                time => $response->{current_spot_time} // $current_time,
                contract => $response,
            }
        ),
        'EX' => DURATION_DONT_PRICE_SAME_SPOT
    );
    my $log_price_daemon_cmd = $params->{log_price_daemon_cmd} // $cmd;
    stats_inc("pricer_daemon.$log_price_daemon_cmd.call", {tags => $self->tags});
    stats_timing("pricer_daemon.$log_price_daemon_cmd.time", $response->{rpc_time}, {tags => $self->tags});
    return $response;
}

sub run {
    my ($self, %args) = @_;
    my $redis = BOM::Config::RedisReplicated::redis_pricer(timeout => 0);

    my $tv_appconfig          = [0, 0];
    my $tv                    = [Time::HiRes::gettimeofday];
    my $stat_count            = {};
    my $current_pricing_epoch = time;

    # Allow ->stop and restart
    local $self->{is_running} = 1;
    while ($self->is_running and (my $key = $redis->brpop(@{$args{queues}}, 0))) {

        # TODO DEBUG CODE, should be removed
        if ($Devel::Confess::STACK_TRACE_ALREADY_RECORDED) {
            Devel::Confess->unimport();
        }
        # DEBUG CODE END

        my $current_eco_cache_epoch = $redis->get('economic_events_cache_snapshot');
        if ($current_eco_cache_epoch and $eco_snapshot != $current_eco_cache_epoch) {
            Volatility::LinearCache::clear_cache();
            $eco_snapshot = $current_eco_cache_epoch;
        }

        # Remember that we had some jobs
        my $tv_now = [Time::HiRes::gettimeofday];
        my $queue  = $key->[0];
        # Apply this for the duration of the current price only
        local $self->{current_queue} = $queue;

        stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv, $tv_now), {tags => $self->tags});
        $tv = $tv_now;

        if (Time::HiRes::tv_interval($tv_appconfig, $tv_now) >= 15) {
            my $rev = BOM::Config::Runtime->instance->app_config->check_for_update;
            # Will return empty if we didn't need to update, so make sure we apply actual
            # version before our check here
            $rev ||= BOM::Config::Runtime->instance->app_config->current_revision;
            $tv_appconfig = $tv_now;
        }

        my $next = $key->[1];
        next unless $next =~ s/^PRICER_KEYS:://;
        my $payload       = decode_json_utf8($next);
        my $params        = {@{$payload}};
        my $contract_type = $params->{contract_type};

        # If incomplete or invalid keys somehow got into pricer,
        # delete them here.
        unless ($self->_validate_params($next, $params)) {
            warn "Invalid parameters: $next";
            $redis->del($key->[1], $next);
            next;
        }

        my $response = $self->process_job($redis, $next, $params) or next;

        if (($response->{rpc_time} // 0) > 1000) {
            my $contract_type_string =
                ref($contract_type)
                ? join '_', @$contract_type
                : $contract_type // 'unknown';
            stats_timing('pricer_daemon.rpc_time', $response->{rpc_time},
                {tags => $self->tags('contract_type:' . $contract_type_string, 'currency:' . $params->{currency})});
        }

        my $subscribers_count = $redis->publish($key->[1], encode_json_utf8($response));
        # if None was subscribed, so delete the job
        if ($subscribers_count == 0) {
            $redis->del($key->[1], $next);
        }

        $tv_now = [Time::HiRes::gettimeofday];

        stats_histogram('pricer_daemon.queue.subscribers', $subscribers_count, {tags => $self->tags});

        stats_timing(
            'pricer_daemon.process.time',
            1000 * Time::HiRes::tv_interval($tv, $tv_now),
            {tags => $self->tags('fork_index:' . $args{fork_index})});
        my $end_time = Time::HiRes::time;
        stats_timing('pricer_daemon.process.end_time', 1000 * ($end_time - int($end_time)), {tags => $self->tags('fork_index:' . $args{fork_index})});
        $stat_count->{$params->{price_daemon_cmd}}++;
        my @stat_redis = (
            pid              => $args{pid},
            ip               => $args{ip},
            process_time     => 1000 * Time::HiRes::tv_interval($tv, $tv_now),
            process_end_time => 1000 * ($end_time - int($end_time)),
            time             => time,
            fork_index       => $args{fork_index});
        $redis->set("PRICER_STATUS::$args{ip}-$args{fork_index}", encode_json_utf8(\@stat_redis));

        if ($current_pricing_epoch != time) {

            for my $key (keys %$stat_count) {
                stats_histogram("pricer_daemon.$key.count_per_second", $stat_count->{$key}, {tags => $self->tags});
            }
            $stat_count            = {};
            $current_pricing_epoch = time;
        }
        $tv = $tv_now;
    }
    return undef;
}

sub _get_underlying_or_log {
    my ($self, $next, $params) = @_;
    my $cmd = $params->{price_daemon_cmd};

    my $underlying = $commands->{$cmd}->{get_underlying}->($self, $params);

    if (not $underlying or not ref($underlying)) {
        warn "Have legacy underlying - $underlying with params " . encode_json_text($params) . "\n" if not ref($underlying);
        stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
        return undef;
    }

    unless (defined $underlying->spot_tick and defined $underlying->spot_tick->epoch) {
        warn "Underlying spot_tick " . Dumper($underlying->spot_tick) if defined $underlying->spot_tick;
        warn $underlying->system_symbol . " has invalid spot tick (request: $next)" if $underlying->calendar->is_open($underlying->exchange);
        stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
        return undef;
    }
    return $underlying;
}

sub _get_underlying_price {
    my ($self, $params) = @_;
    unless (exists $params->{symbol}) {
        warn "symbol is not provided price daemon for price";
        return undef;
    }
    return create_underlying($params->{symbol});
}

sub _get_underlying_bid {
    my ($self, $params) = @_;
    unless (exists $params->{short_code} and $params->{currency}) {
        warn "short_code or currency is not provided price daemon for bid";
        return undef;
    }
    my $from_shortcode = shortcode_to_parameters($params->{short_code}, $params->{currency});
    return create_underlying($from_shortcode->{underlying});
}

sub _process_price {
    my ($self, $params) = @_;
    $params->{streaming_params}->{add_theo_probability} = 1;
    # we want to log proposal array under different key
    $params->{log_price_daemon_cmd} = 'price_batch' if $params->{proposal_array};
    return BOM::Pricing::v3::Contract::send_ask({args => $params});
}

sub _process_bid {
    my ($self, $params) = @_;
    $params->{validation_params}->{skip_barrier_validation} = 1;
    return BOM::Pricing::v3::Contract::send_bid($params);
}

sub _validate_params {
    my ($self, $next, $params) = @_;

    my $cmd = $params->{price_daemon_cmd};
    unless ($cmd) {
        warn "No Pricer command! Payload is: " . ($next // 'undefined');
        stats_inc("pricer_daemon.no_cmd", {tags => $self->tags});
        return 0;
    }
    unless (defined($commands->{$cmd})) {
        warn "Unrecognized Pricer command $cmd! Payload is: " . ($next // 'undefined');
        stats_inc("pricer_daemon.unknown.invalid", {tags => $self->tags});
        return 0;
    }
    if (first { not defined $params->{$_} } @{$commands->{$cmd}{required_params}}) {
        warn "Not all required params provided for $cmd! Payload is: " . ($next // 'undefined');
        stats_inc("pricer_daemon.required_params_missed", {tags => $self->tags});
        return 0;
    }
    return 1;
}

=head2 current_queue

The name of the queue we're currently processing. May be undef.

=cut

sub current_queue {
    return shift->{current_queue};
}

=head2 tags

Returns an arrayref of datadog tags. Takes an optional list of additional tags to apply.

=cut

sub tags {
    my ($self, @tags) = @_;
    return [@{$self->{tags}}, map { ; "tag:$_" } $self->current_queue // (), @tags];
}

# TODO DEBUG code, should be removed
# This debug code is for card https://trello.com/c/PVt9CRyc/8930-move-pricedaemon-warnings-to-metrics
# I think when we set pricer timeout to 0, the error will be disappeared. But I want to confirm
# there is no other places that cause the error 'Resource temporarily unavailable'.
# So I introduced the `Devel::Confess`. And I want to suppress the errors caused by redis commands.
# I believe these errors should disappear, but it will be safer to wrap it by hand.
# If there is no 'pricer_daemon.resource_unavailable_error' in statsd, then the debug code can be dropped.

package RedisDB;    ## no critic (ProhibitMultiplePackages)
use Class::Method::Modifiers;
use Try::Tiny;
use Scalar::Util qw(blessed);
use feature qw(state);
use DataDog::DogStatsd::Helper qw/stats_inc/;

around execute => sub {
    Devel::Confess->unimport();
    my $orig       = shift;
    my @args       = @_;
    my $died_count = 0;
    my $err;
    my $result;
    my $max_retry = 10;
    for (1 .. $max_retry) {
        undef $err;
        try {
            $result = $orig->(@args);
        }
        catch {
            $died_count++;
            $err = $_;
            if (blessed($err) && $err->isa('RedisDB::Error::EAGAIN')) {
                stats_inc("pricer_daemon.resource_unavailable_error");
            }
        };

        # we retry only when the error is EAGAIN
        last unless blessed($err) && $err->isa('RedisDB::Error::EAGAIN');
    }

    die "command @_ failed: $err" if $died_count == $max_retry || ($err && (!blessed($err) || !$err->isa('RedisDB:Error::EAGAIN')));
    Devel::Confess->import();
    return $result;
};

# DEBUG CODE END
1;


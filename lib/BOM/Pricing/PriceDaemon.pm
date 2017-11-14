package BOM::Pricing::PriceDaemon;

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw/stats_inc stats_gauge stats_count stats_timing/;
use Encode;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use JSON::MaybeXS;
use List::Util qw(first);
use Time::HiRes ();
use Try::Tiny;

use BOM::MarketData qw(create_underlying);
use BOM::Platform::Context;
use BOM::Platform::RedisReplicated;
use BOM::Platform::Runtime;
use BOM::Pricing::v3::Contract;

use constant {
    DURATION_DONT_PRICE_SAME_SPOT                        => 10,
    DURATION_RETURN_SAME_PRICE_ON_SAME_SPOT_FOR_PRIORITY => 2,
};

sub new { return bless {@_[1 .. $#_]}, $_[0] }

sub process_job {
    my ($self, $redis, $next, $params) = @_;

    my $log_price_daemon_cmd = my $price_daemon_cmd = $params->{price_daemon_cmd} || '';
    my $current_time = time;
    my $response;

    my $underlying = $self->_get_underlying($params) or return undef;
    my $json = JSON::MaybeXS->new();

    if (!ref($underlying)) {
        warn "Have legacy underlying - $underlying with params " . $json->encode($params) . "\n";
        stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => $self->tags});
        return undef;
    }

    # We can skip ICO entries entirely. Websockets layer has no idea what an ICO is, so
    # we can't filter them out of the pricing keys at that level - if the extra queue
    # entries start to cause a problem we can drop them in pricer_queue.pl instead.
    return undef if $underlying->symbol eq 'BINARYICO';

    unless (defined $underlying->spot_tick and defined $underlying->spot_tick->epoch) {
        warn $underlying->system_symbol . " has invalid spot tick" if $underlying->calendar->is_open($underlying->exchange);
        stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => $self->tags});
        return undef;
    }

    my $current_spot_ts      = $underlying->spot_tick->epoch;
    my $last_priced_contract = try { $json->decode(Encode::decode_utf8($redis->get($next))) } catch { {time => 0} };
    my $last_price_ts        = $last_priced_contract->{time};

    # For plain queue, if we have request for a price, and tick has not changed since last one, and it was not more
    # than 10 seconds ago - just ignore it.
    # For priority, we're sending rnevious request at this case
    if ($current_spot_ts == $last_price_ts) {
        if ($current_time - $last_price_ts <= DURATION_DONT_PRICE_SAME_SPOT
            and not $self->_is_in_priority_queue())
        {
            stats_inc("pricer_daemon.skipped_duplicate_spot", {tags => $self->tags});
            return undef;
        } elsif ($current_time - $last_price_ts <= DURATION_RETURN_SAME_PRICE_ON_SAME_SPOT_FOR_PRIORITY
            and $self->_is_in_priority_queue())
        {
            stats_inc("pricer_daemon.existing_price_used", {tags => $self->tags});
            return $last_priced_contract->{contract};
        }
    }

    my $r = BOM::Platform::Context::Request->new({language => $params->{language} // 'EN'});
    BOM::Platform::Context::request($r);

    if ($price_daemon_cmd eq 'price') {
        $params->{streaming_params}->{add_theo_probability} = 1;
        $response = BOM::Pricing::v3::Contract::send_ask({args => $params});
        # we want to log proposal array under different key
        $log_price_daemon_cmd = 'price_batch' if $params->{proposal_array};
    } elsif ($price_daemon_cmd eq 'bid') {
        $params->{validation_params}->{skip_barrier_validation} = 1;
        $response = BOM::Pricing::v3::Contract::send_bid($params);
    } else {
        warn "Unrecognized Pricer command! Payload is: " . ($next // 'undefined');
        stats_inc("pricer_daemon.unknown.invalid", {tags => $self->tags});
        return undef;
    }

    $response->{price_daemon_cmd} = $price_daemon_cmd;
    # contract parameters are stored after first call, no need to send them with every stream message
    delete $response->{contract_parameters} if not $self->_is_in_priority_queue;

    # when it reaches here, contract is considered priced.
    $redis->set(
        $next => Encode::encode_utf8(
            $json->encode({
                    time     => $current_time,
                    contract => $response,
                })
        ),
        'EX' => DURATION_DONT_PRICE_SAME_SPOT
    );

    stats_inc("pricer_daemon.$log_price_daemon_cmd.call", {tags => $self->tags});
    stats_timing("pricer_daemon.$log_price_daemon_cmd.time", $response->{rpc_time}, {tags => $self->tags});
    return $response;
}

sub run {
    my ($self, %args) = @_;
    my $redis = BOM::Platform::RedisReplicated::redis_pricer;

    my $tv_appconfig          = [0, 0];
    my $tv                    = [Time::HiRes::gettimeofday];
    my $stat_count            = {};
    my $current_pricing_epoch = time;
    my $json                  = JSON::MaybeXS->new();
    while (my $key = $redis->brpop(@{$args{queues}}, 0)) {
        # Remember that we had some jobs
        my $tv_now = [Time::HiRes::gettimeofday];
        my $queue  = $key->[0];
        # Apply this for the duration of the current price only
        local $self->{current_queue} = $queue;

        stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv, $tv_now), {tags => $self->tags});
        $tv = $tv_now;

        if (Time::HiRes::tv_interval($tv_appconfig, $tv_now) >= 15) {
            my $rev = BOM::Platform::Runtime->instance->app_config->check_for_update;
            # Will return empty if we didn't need to update, so make sure we apply actual
            # version before our check here
            $rev ||= BOM::Platform::Runtime->instance->app_config->current_revision;
            $tv_appconfig = $tv_now;
        }

        my $next = $key->[1];
        next unless $next =~ s/^PRICER_KEYS:://;
        my $payload       = $json->decode(Encode::decode_utf8($next));
        my $params        = {@{$payload}};
        my $contract_type = $params->{contract_type};

        # If incomplete or invalid keys somehow got into pricer,
        # delete them here.
        unless ($self->_validate_params($params)) {
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

        my $subscribers_count = $redis->publish($key->[1], Encode::encode_utf8($json->encode($response)));
        # if None was subscribed, so delete the job
        if ($subscribers_count == 0) {
            $redis->del($key->[1], $next);
        }

        $tv_now = [Time::HiRes::gettimeofday];

        stats_count('pricer_daemon.queue.subscribers', $subscribers_count, {tags => $self->tags});
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
        $redis->set("PRICER_STATUS::$args{ip}-$args{fork_index}", Encode::encode_utf8($json->encode(\@stat_redis)));

        if ($current_pricing_epoch != time) {

            for my $key (keys %$stat_count) {
                stats_gauge("pricer_daemon.$key.count_per_second", $stat_count->{$key}, {tags => $self->tags});
            }
            $stat_count            = {};
            $current_pricing_epoch = time;
        }
        $tv = $tv_now;
    }
    return undef;
}

sub _get_underlying {
    my ($self, $params) = @_;

    my $cmd = $params->{price_daemon_cmd};

    return undef unless $cmd;

    if ($cmd eq 'price') {
        unless (exists $params->{symbol}) {
            warn "symbol is not provided price daemon for $cmd";
            stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
            return undef;
        }
        return create_underlying($params->{symbol});
    } elsif ($cmd eq 'bid') {
        unless (exists $params->{short_code} and $params->{currency}) {
            warn "short_code or currency is not provided price daemon for $cmd";
            stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
            return undef;
        }
        my $from_shortcode = shortcode_to_parameters($params->{short_code}, $params->{currency});
        return create_underlying($from_shortcode->{underlying});
    }

    return;
}

my %required_params = (
    price => [qw(contract_type currency symbol)],
    bid   => [qw(contract_id short_code currency landing_company)],
);

sub _validate_params {
    my ($self, $params) = @_;

    my $cmd = $params->{price_daemon_cmd};
    return 0 unless $cmd;
    return 0 unless $cmd eq 'price' or $cmd eq 'bid';
    return 0 if first { not defined $params->{$_} } @{$required_params{$cmd}};
    return 1;
}

sub _is_in_priority_queue {
    my $self = shift;
    return $self->{current_queue} eq 'pricer_jobs_priority';
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

1;


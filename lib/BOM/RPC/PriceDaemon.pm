package BOM::RPC::PriceDaemon;

use strict;
use warnings;

sub process_job {
    my ($self, $redis, $next, $params) = @_;

    my $price_daemon_cmd = $params->{price_daemon_cmd} || '';
    my $current_time = time;
    my $response;

    my $underlying = _get_underlying($params) or return undef;

    if (!ref($underlying)) {
        warn "Have legacy underlying - $underlying with params " . Dumper($params) . "\n";
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => ['tag:' . $internal_ip]});
        return undef;
    }

    unless (defined $underlying->spot_tick and defined $underlying->spot_tick->epoch) {
        warn "$params->{symbol} has invalid spot tick" if $underlying->calendar->is_open;
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => ['tag:' . $internal_ip]});
        return undef;
    }

    my $current_spot_ts = $underlying->spot_tick->epoch;
    my $last_price_ts = $redis->get($next) || 0;

    return undef if ($current_spot_ts == $last_price_ts and $current_time - $last_price_ts <= 10);

    if ($price_daemon_cmd eq 'price') {
        $params->{streaming_params}->{add_theo_probability} = 1;
        if (exists $params->{barriers}) {
            $response = BOM::RPC::v3::Contract::send_multiple_ask({args => $params});
        } else {
            $response = BOM::RPC::v3::Contract::send_ask({args => $params});
        }
    } elsif ($price_daemon_cmd eq 'bid') {
        $params->{validation_params}->{skip_barrier_validation} = 1;
        $response = BOM::RPC::v3::Contract::send_bid($params);
    } else {
        warn "Unrecognized Pricer command! Payload is: " . ($next // 'undefined');
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.unknown.invalid", {tags => ['tag:' . $internal_ip]});
        return undef;
    }

    # when it reaches here, contract is considered priced.
    $redis->set($next, $current_time);
    $redis->expire($next, 300);

    DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.call", {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_timing("pricer_daemon.$price_daemon_cmd.time", $response->{rpc_time}, {tags => ['tag:' . $internal_ip]});
    $response->{price_daemon_cmd} = $price_daemon_cmd;
    return $response;
}

sub run {
    my ($self, %args) = @_;
    my $redis = BOM::System::RedisReplicated::redis_pricer;

    my $tv_appconfig          = [0, 0];
    my $tv                    = [Time::HiRes::gettimeofday];
    my $stat_count            = {};
    my $current_pricing_epoch = time;
    for my $queue (@{$args{queues}}) {
        while(my $key = $redis->brpop($queue, 0)) {
            my $tv_now = [Time::HiRes::gettimeofday];
            DataDog::DogStatsd::Helper::stats_timing(
                'pricer_daemon.idle.time',
                1000 * Time::HiRes::tv_interval($tv, $tv_now),
                {tags => ['tag:' . $internal_ip]});
            $tv = $tv_now;

            if (Time::HiRes::tv_interval($tv_appconfig, $tv_now) >= 15) {
                my $rev = BOM::Platform::Runtime->instance->app_config->check_for_update;
                # Will return empty if we didn't need to update, so make sure we apply actual
                # version before our check here
                $rev ||= BOM::Platform::Runtime->instance->app_config->current_revision;
                my $age = Time::HiRes::time - $rev;
                warn "Config age is >90s - $age\n" if $age > 90;
                $tv_appconfig = $tv_now;
            }

            my $next = $key->[1];
            next unless $next =~ s/^PRICER_KEYS:://;
            my $payload = JSON::XS::decode_json($next);
            my $params  = {@{$payload}};

            # If incomplete or invalid keys somehow got into pricer,
            # delete them here.
            unless (_validate_params($params)) {
                warn "Invalid parameters: " . Data::Dumper->Dumper($params);
                $redis->del($key->[1], $next);
                next;
            }

            my $response = txn {
                $self->process_job($redis, $next, $params);
            }
            qw(feed chronicle) or next;

            warn "Pricing time too long: "
                . $response->{rpc_time} . ': '
                . join(', ', map $_ . " = " . ($params->{$_} // '"undef"'), sort keys %$params) . "\n"
                if $response->{rpc_time} > 1000;

            my $subscribers_count = $redis->publish($key->[1], encode_json($response));
            # if None was subscribed, so delete the job
            if ($subscribers_count == 0) {
                $redis->del($key->[1], $next);
            }

            $tv_now = [Time::HiRes::gettimeofday];

            DataDog::DogStatsd::Helper::stats_count('pricer_daemon.queue.subscribers', $subscribers_count, {tags => ['tag:' . $internal_ip]});
            DataDog::DogStatsd::Helper::stats_timing(
                'pricer_daemon.process.time',
                1000 * Time::HiRes::tv_interval($tv, $tv_now),
                {tags => ['tag:' . $internal_ip]});
            my $end_time = Time::HiRes::time;
            DataDog::DogStatsd::Helper::stats_timing(
                'pricer_daemon.process.end_time',
                1000 * ($end_time - int($end_time)),
                {tags => ['tag:' . $internal_ip]});
            $stat_count->{$params->{price_daemon_cmd}}++;
            if ($current_pricing_epoch != time) {

                for my $key (keys %$stat_count) {
                    DataDog::DogStatsd::Helper::stats_gauge("pricer_daemon.$key.count_per_second", $stat_count->{$key},
                        {tags => ['tag:' . $internal_ip]});
                }
                $stat_count            = {};
                $current_pricing_epoch = time;
            }
            $tv = $tv_now;
        }
    }
}

sub _get_underlying {
    my $params = shift;

    my $cmd = $params->{price_daemon_cmd};

    return unless $cmd;

    if ($cmd eq 'price') {
        unless (exists $params->{symbol}) {
            warn "symbol is not provided price daemon for $cmd";
            DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$cmd.invalid", {tags => ['tag:' . $internal_ip]});
            return undef;
        }
        return create_underlying($params->{symbol});
    } elsif ($cmd eq 'bid') {
        unless (exists $params->{short_code} and $params->{currency}) {
            warn "short_code or currency is not provided price daemon for $cmd";
            DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$cmd.invalid", {tags => ['tag:' . $internal_ip]});
            return undef;
        }
        my $from_shortcode = shortcode_to_parameters($params->{short_code}, $params->{currency});
        return $from_shortcode->{underlying};
    }

    return;
}

sub _validate_params {
    my $params = shift;

    my $cmd = $params->{price_daemon_cmd};
    return 0 unless $cmd;
    return 0 unless $cmd eq 'price' or $cmd eq 'bid';
    return 0 if first { not defined $params->{$_} } @{$required_params{$cmd}};
    return 1;
}

1;


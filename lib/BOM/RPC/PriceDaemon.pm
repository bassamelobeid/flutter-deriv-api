package BOM::RPC::PriceDaemon;

use strict;
use warnings;

use DBIx::TransactionManager::Distributed qw(txn);
use List::Util qw(first);
use Time::HiRes ();
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory::Parser qw(shortcode_to_parameters);
use JSON::XS qw/encode_json decode_json/;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use BOM::RPC::v3::Contract;

sub new { return bless {@_[1 .. $#_]}, $_[0] }

sub process_job {
    my ($self, $redis, $next, $params) = @_;

    my $price_daemon_cmd = $params->{price_daemon_cmd} || '';
    my $current_time = time;
    my $response;

    my $underlying = $self->_get_underlying($params) or return undef;

    if (!ref($underlying)) {
        warn "Have legacy underlying - $underlying with params " . encode_json($params) . "\n";
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => $self->tags});
        return undef;
    }

    unless (defined $underlying->spot_tick and defined $underlying->spot_tick->epoch) {
        warn "$params->{symbol} has invalid spot tick" if $underlying->calendar->is_open;
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.invalid", {tags => $self->tags});
        return undef;
    }

    my $current_spot_ts = $underlying->spot_tick->epoch;
    my $last_price_ts = $redis->get($next) || 0;

    return undef if ($current_spot_ts == $last_price_ts and $current_time - $last_price_ts <= 10);

    if ($price_daemon_cmd eq 'price') {
        $params->{streaming_params}->{add_theo_probability} = 1;
        $response = BOM::RPC::v3::Contract::send_ask({args => $params});
        delete @$response{qw(longcode contract_parameters)};    # stored in stash after first call
    } elsif ($price_daemon_cmd eq 'bid') {
        $params->{validation_params}->{skip_barrier_validation} = 1;
        $response = BOM::RPC::v3::Contract::send_bid($params);
    } else {
        warn "Unrecognized Pricer command! Payload is: " . ($next // 'undefined');
        DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.unknown.invalid", {tags => $self->tags});
        return undef;
    }

    # when it reaches here, contract is considered priced.
    $redis->set($next, $current_time);
    $redis->expire($next, 300);

    DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$price_daemon_cmd.call", {tags => $self->tags});
    DataDog::DogStatsd::Helper::stats_timing("pricer_daemon.$price_daemon_cmd.time", $response->{rpc_time}, {tags => $self->tags});
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
    while (my $key = $redis->brpop(@{$args{queues}}, 0)) {
        # Remember that we had some jobs
        my $tv_now = [Time::HiRes::gettimeofday];
        my $queue  = $key->[0];
        # Apply this for the duration of the current price only
        local $self->{current_queue} = $queue;

        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.idle.time', 1000 * Time::HiRes::tv_interval($tv, $tv_now), {tags => $self->tags});
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
        my $payload = decode_json($next);
        my $params  = {@{$payload}};

        # If incomplete or invalid keys somehow got into pricer,
        # delete them here.
        unless ($self->_validate_params($params)) {
            warn "Invalid parameters: $next";
            $redis->del($key->[1], $next);
            next;
        }

        my $response = txn {
            $self->process_job($redis, $next, $params);
        }
        qw(feed chronicle) or next;

        warn "Pricing time too long: "
            . $response->{rpc_time} . ': '
            . join(', ', map { ; $_ . " = " . ($params->{$_} // '"undef"') } sort keys %$params) . "\n"
            if $response->{rpc_time} > 1000;

        my $subscribers_count = $redis->publish($key->[1], encode_json($response));
        # if None was subscribed, so delete the job
        if ($subscribers_count == 0) {
            $redis->del($key->[1], $next);
        }

        $tv_now = [Time::HiRes::gettimeofday];

        DataDog::DogStatsd::Helper::stats_count('pricer_daemon.queue.subscribers', $subscribers_count, {tags => $self->tags});
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.time', 1000 * Time::HiRes::tv_interval($tv, $tv_now), {tags => $self->tags});
        my $end_time = Time::HiRes::time;
        DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.process.end_time', 1000 * ($end_time - int($end_time)), {tags => $self->tags});
        $stat_count->{$params->{price_daemon_cmd}}++;
        if ($current_pricing_epoch != time) {

            for my $key (keys %$stat_count) {
                DataDog::DogStatsd::Helper::stats_gauge("pricer_daemon.$key.count_per_second", $stat_count->{$key}, {tags => $self->tags});
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
            DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
            return undef;
        }
        return create_underlying($params->{symbol});
    } elsif ($cmd eq 'bid') {
        unless (exists $params->{short_code} and $params->{currency}) {
            warn "short_code or currency is not provided price daemon for $cmd";
            DataDog::DogStatsd::Helper::stats_inc("pricer_daemon.$cmd.invalid", {tags => $self->tags});
            return undef;
        }
        my $from_shortcode = shortcode_to_parameters($params->{short_code}, $params->{currency});
        return $from_shortcode->{underlying};
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


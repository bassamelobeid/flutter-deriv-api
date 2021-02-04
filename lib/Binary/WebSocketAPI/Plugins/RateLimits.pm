package Binary::WebSocketAPI::Plugins::RateLimits;

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Plugin';
use Future::Mojo;
use Time::Duration::Concise;
use Variable::Disposition qw/retain_future/;
use YAML::XS qw(LoadFile);
use Log::Any qw($log);
use Cache::LRU;

sub register {
    my ($self, $app) = @_;

    ### rate-limitation plugin
    my %rates_files = (binary => LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/perl_rate_limitations.yml'));

    my %rates_config;
    # convert configuration
    # (i.e. unify human-readable time intervals like '1m' to seconds (60))
    for my $company (keys %rates_files) {
        my $rates_file_content = $rates_files{$company};
        for my $service (keys %$rates_file_content) {
            for my $interval (keys %{$rates_file_content->{$service}}) {
                my $seconds_ttl = Time::Duration::Concise->new(interval => $interval)->seconds;
                my $limit       = $rates_file_content->{$service}->{$interval};
                my $limit_name  = "${service}.${interval}";

                push @{$rates_config{$company}{$service}},
                    {
                    name  => $limit_name,
                    limit => $limit,
                    ttl   => $seconds_ttl,
                    };
            }
        }
    }

    $app->{_binary}{rates_config} = \%rates_config;

    # Returns a Future which will resolve as 'done' if services usage limit wasn't hit,
    # and 'fail' otherwise
    $app->helper(check_limits => \&_check_limits);

    return;
}

sub _update_redis {
    my ($c, $name, $ttl) = @_;

    my $diff = _limits_cache($c, $name)->{pending};
    # update_in_progress blocks other updates from starting
    _limits_cache(
        $c, $name,
        pending            => 0,
        update_in_progress => 1
    );

    my $client_id = $c->rate_limitations_key;
    my $redis     = $c->app->ws_redis_master;
    my $redis_key = $client_id . '::' . $name;
    my $f         = Future::Mojo->new;
    $redis->incrby(
        $redis_key,
        $diff,
        sub {
            my ($redis, $error, $count) = @_;
            # We can do nothing useful if we are already shutting down
            return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

            if ($error) {
                $log->warn("Redis error: $error");
                return $f->fail($error);
            }
            # overwrite by force speculatively calculated value
            _limits_cache(
                $c, $name,
                value              => $count,
                update_in_progress => 0
            );
            # print "[debug] update from redis $name => $count\n";

            # Count should always go up, or expire. If we had no key or expired,
            # then our returned value should match the increment value... so we'd
            # want to set expiry in that case.
            if ($count == $diff) {
                _set_key_expiry($c, $redis_key, $ttl, $f);
            } else {
                $redis->ttl(
                    $redis_key,
                    sub {
                        my ($redis, $error, $redis_ttl) = @_;
                        if ($error) {
                            $log->warn("Redis error: $error");
                            return $f->fail($error);
                        }
                        # If ttl == -2 the key has just expired and we don't need a warning here.
                        _set_key_expiry($c, $redis_key, $ttl) if $redis_ttl == -1;
                    });
                $f->done;
            }
            # retrigger scheduled updates
            if (_limits_cache($c, $name)->{pending}) {
                _update_redis($c, $name, $ttl);
            }
        });
    return $f;
}

sub _set_key_expiry {
    my ($c, $redis_key, $ttl, $f) = @_;
    my $redis  = $c->app->ws_redis_master;
    my @caller = caller;
    $redis->expire(
        $redis_key,
        $ttl,
        sub {
            my ($redis, $error, $confirmation) = @_;
            # TODO this line is for debug, should be removed later.
            # https://trello.com/c/ucCVDdSp/73-logs-expirationnotconfirmed
            local $log->context->{caller} = \@caller;
            $log->error("Error when set key $redis_key expiry: $error") if $error;
            $log->info("Expiration on $redis_key was not confirmed")
                unless $confirmation;
            $f->done if $f;
        });
    return;
}

sub _check_single_limit {
    my ($c, $limit_descriptor) = @_;
    my $name = $limit_descriptor->{name};
    # update value speculatively (i.e. before getting real values from redis)
    my $local_storage = _limits_cache($c, $name);
    _limits_cache(
        $c, $name,
        pending => ++$local_storage->{pending},
        value   => ++$local_storage->{value});
    my $value  = $local_storage->{value};
    my $result = $value <= $limit_descriptor->{limit};
    # print "[debug] $name check => $result (value: $value)\n";

    my $f =
        _limits_cache($c, $name)->{update_in_progress}
        ? Future->done
        : _update_redis($c, $name, $limit_descriptor->{ttl});
    return ($result, $f);
}

sub _check_limits {
    my ($c, $service) = @_;

    return Future->done if _app_rate_limit_is_disabled($c);

    my $rates_config      = $c->app->{_binary}{rates_config};
    my $limits_domain     = $rates_config->{$c->landing_company_name // ''} // $rates_config->{binary};
    my $limit_descriptors = $limits_domain->{$service};

    my @future_checks;
    my $speculative_result = 1;
    for my $descr (@$limit_descriptors) {
        my ($atomic_result, $atomic_future) = _check_single_limit($c, $descr);
        $speculative_result &&= $atomic_result;
        push @future_checks, $atomic_future;
    }
    # do updates in parallel (in background)
    retain_future(Future->wait_all(@future_checks));
    return $speculative_result ? Future->done : Future->fail('limit hit');
}

=head2 _app_rate_limit_is_disabled

Checks to see if the given app rate-limit is disabled or not?
Returns C<true> if rate-limit is disabled and false otherwise.

=over 4

=item * C<$c> - websocket connection object

=back

Returns boolean

=cut

sub _app_rate_limit_is_disabled {
    my $c = shift;

    my $app_redis_key      = sprintf('app_id::disable_rate_limit::%s', $c->app_id);
    my $disable_rate_limit = $c->app->ws_redis_master->get($app_redis_key) // 0;

    return $disable_rate_limit eq 'bypass';
}

=head2 _limits_cache

Creates an application level LRU cache if it doesn't exist.
This will persist limit info on this worker after reconnect if the IP and user agent are the same.

=over 4

=item * C<$c> - websocket connection object

=item * C<$name> - limit name

=item * C<%updates> - optional key/value pairs to update

=back

Returns hashref of cached values for the provided $name.

=cut

sub _limits_cache {
    my ($c, $name, %updates) = @_;
    my $cache       = $c->app->{_binary}{rate_limits} //= Cache::LRU->new(size => 10000);
    my $client_id   = $c->rate_limitations_key;
    my $cache_entry = $cache->get($client_id) // {};
    if (%updates) {
        $cache_entry->{$name}{$_} = $updates{$_} for keys %updates;
        $cache->set($client_id, $cache_entry);
    }
    return $cache_entry->{$name} // {};
}

1;

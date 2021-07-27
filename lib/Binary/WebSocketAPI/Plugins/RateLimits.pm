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

    $app->{_binary}{rate_limits_storage} = Cache::LRU->new(size => 10000);

    # Returns a Future which will resolve as 'done' if services usage limit wasn't hit,
    # and 'fail' otherwise
    $app->helper(check_limits => \&_check_limits);

    return;
}

sub _update_redis {
    my ($c, $name, $ttl) = @_;
    my $local_storage = $c->stash->{rate_limits} //= {};
    my $diff = $local_storage->{$name}{pending};

    $local_storage->{$name}{pending}            = 0;
    $local_storage->{$name}{update_in_progress} = $diff;

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
            # sync redis value to cache
            _limits_cache($c, $name, value => $count);
            $local_storage->{$name}{update_in_progress} = 0;
            # print "[debug] update from redis $name => $count\n";

            # Count should always go up, or expire. If we had no key or expired,
            # then our returned value should match the increment value... so we'd
            # want to set expiry in that case.
            if ($count == $diff) {
                _set_key_expiry($c, $redis_key, $ttl, $f, $name);
            } else {
                $redis->ttl(
                    $redis_key,
                    sub {
                        my ($redis, $error, $redis_ttl) = @_;
                        if ($error) {
                            $log->warn("Redis error: $error");
                            return $f->fail($error);
                        }
                        # ttl -2: key doesn't exist - remove from cache
                        _limits_cache($c, $name, expired => 1) if $redis_ttl == -2;
                        # ttl -1: no ttl set yet
                        _set_key_expiry($c, $redis_key, $ttl, undef, $name) if $redis_ttl == -1;
                        # sync redis ttl to cache
                        _limits_cache($c, $name, ttl => $redis_ttl) if $redis_ttl > 0;
                    });
                $f->done;
            }
            # retrigger scheduled updates
            if ($local_storage->{$name}{pending}) {
                _update_redis($c, $name, $ttl);
            }
        });
    return $f;
}

sub _set_key_expiry {
    my ($c, $redis_key, $ttl, $f, $name) = @_;
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
    # sync redis ttl to cache
    _limits_cache($c, $name, ttl => $ttl);
    return;
}

sub _check_single_limit {
    my ($c, $limit_descriptor) = @_;
    my $name = $limit_descriptor->{name};
    my $local_storage = $c->stash->{rate_limits} //= {};

    # update value speculatively (i.e. before getting real values from redis)
    my $value = _limits_cache($c, $name)->{value};
    $value += ++$local_storage->{$name}{pending};
    $value += $local_storage->{$name}{update_in_progress} // 0;

    my $result = $value <= $limit_descriptor->{limit};
    # print "[debug] $name check => $result (value: $value)\n";

    my $f =
        $local_storage->{$name}{update_in_progress}
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

Provdes application level LRU cache of client limits.
This will persist limit info on this worker after reconnect if the IP and user agent are the same.

=over 4

=item * C<$c> - websocket connection object

=item * C<$name> - limit name

=item * C<%updates> - optional key/value pairs to update:

=over 8

=item * C<ttl> - expiry in seconds

=item * C<value> - limit value

=back

=back

Returns hashref of cached values for the provided $name.

=cut

sub _limits_cache {
    my ($c, $name, %updates) = @_;
    my $cache       = $c->app->{_binary}{rate_limits_storage};
    my $client_id   = $c->rate_limitations_key;
    my $cache_entry = $cache->get($client_id) // {};

    $updates{expired} = 1        if $cache_entry->{$name}{expiry_ts} and time > $cache_entry->{$name}{expiry_ts};
    delete $cache_entry->{$name} if $updates{expired};

    $cache_entry->{$name}{expiry_ts} = time + $updates{ttl} if $updates{ttl};
    $cache_entry->{$name}{value}     = $updates{value}      if $updates{value};
    $cache->set($client_id, $cache_entry) if %updates;

    return $cache_entry->{$name} // {value => 0};
}

1;

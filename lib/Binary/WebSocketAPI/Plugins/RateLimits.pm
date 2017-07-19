package Binary::WebSocketAPI::Plugins::RateLimits;

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Plugin';
use Future::Mojo;
use Time::Duration::Concise;
use Variable::Disposition qw/retain_future/;
use YAML::XS qw(LoadFile);

sub register {
    my ($self, $app) = @_;

    ### rate-limitation plugin
    my %rates_files = (
        binary => LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/perl_rate_limitations.yml'),
        japan  => LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/japan_perl_rate_limitations.yml'));

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

    # returns future, which will be 'done' if services usage limit wasn't hit,
    # and 'fail' otherwise
    $app->helper(check_limits => \&_check_limits);

    return;
}

sub _update_redis {
    my ($c, $name, $ttl) = @_;
    my $local_storage = $c->stash->{rate_limits} //= {};
    my $diff = $local_storage->{$name}{pending};

    $local_storage->{$name}{pending}            = 0;
    $local_storage->{$name}{update_in_progress} = 1;

    my $client_id = $c->rate_limitations_key;
    my $redis     = $c->app->ws_redis_master;
    my $redis_key = $client_id . '::' . $name;
    my $f         = Future::Mojo->new;
    $redis->incrby(
        $redis_key,
        $diff,
        sub {
            my ($redis, $error, $count) = @_;
            if ($error) {
                $c->app->log->warn("Redis error: $error");
                return $f->fail($error);
            }
            # overwrite by force speculatively calculated value
            $local_storage->{$name}{value}              = $count;
            $local_storage->{$name}{update_in_progress} = 0;
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
                            $c->app->log->warn("Redis error: $error");
                            return $f->fail($error);
                        }
                        # if ttl == -2 the key has just expired and we dont need a warning here.
                        _set_key_expiry($c, $redis_key, $ttl) if $redis_ttl == -1;
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
    my ($c, $redis_key, $ttl, $f) = @_;
    my $redis = $c->app->ws_redis_master;
    $redis->expire(
        $redis_key,
        $ttl,
        sub {
            my ($redis, $error, $confirmation) = @_;
            $c->app->log->warn("Expiration on $redis_key was not confirmed")
                unless $confirmation;
            $f->done if $f;
        });
    return;
}

sub _check_single_limit {
    my ($c, $limit_descriptor) = @_;
    my $name = $limit_descriptor->{name};
    my $local_storage = $c->stash->{rate_limits} //= {};
    # update value speculatively (i.e. before getting real values from redis)
    ++$local_storage->{$name}{pending};
    my $value  = ++$local_storage->{$name}{value};
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
    # do updates in paralell (in background)
    retain_future(Future->wait_all(@future_checks));
    return $speculative_result ? Future->done : Future->fail('limit hit');
}

1;

package Binary::WebSocketAPI::Plugins::RateLimits;

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Plugin';
use Future::Mojo;
use Time::Duration::Concise;
use Variable::Disposition qw/retain_future/;
use YAML::XS qw(LoadFile);

sub register {
    my ($self, $app, $conf) = @_;

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

    $app->helper(
        # returns future, which will be 'done' if services usage limit wasn't hit,
        # and 'fail' otherwise
        check_limits => sub {
            _check_limits(@_);
        });
}

sub _check_single_limit {
    my ($c, $limit_descriptor) = @_;
    my $name = $limit_descriptor->{name};
    my $local_storage = $c->stash->{rate_limits} //= {};
    # update value speculatively (i.e. before getting real values from redis)
    my $value = ++($local_storage->{$name} //= 0);
    my $result = $value <= $limit_descriptor->{limit};
    print "[debug] $name check => $result ($value)\n";

    my $client_id = $c->rate_limitations_key;
    my $redis     = $c->app->ws_redis_master;
    my $redis_key = $name . $client_id;
    my $f         = Future::Mojo->new;
    $redis->incr(
        $redis_key,
        sub {
            my ($redis, $error, $count) = @_;
            if ($error) {
                $c->app->log->warn("Redis error: $error");
                return $f->fail($error) if $error;
            }
            # overwrite by force speculatively calculated value
            $local_storage->{$name} = $count;
            print "[debug] $name => $count\n";
            if ($count == 1) {
                $redis->expire(
                    $redis_key,
                    $limit_descriptor->{ttl},
                    sub {
                        my ($redis, $error, $confirmation) = @_;
                        $c->app->log->warn("Expiration on $redis_key was not confirmed")
                            unless $confirmation;
                        $f->done;
                    });
            } else {
                $f->done;
            }
        });
    return ($result, $f);
}

sub _check_limits {
    my ($c, $service) = @_;
    my $rates_config      = $c->app->{_binary}{rates_config};
    my $client_id         = $c->rate_limitations_key;
    my $limits_domain     = $rates_config->{$c->landing_company_name // ''} // $rates_config->{binary};
    my $limit_descriptors = $limits_domain->{$service};

    my $redis = $c->app->ws_redis_master;
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

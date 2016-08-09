package Binary::WebSocketAPI::Plugins::Helpers;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use feature "state";
use Sys::Hostname;
use YAML::XS;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Locale::Maketext::ManyPluralForms {
    'EN'      => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/en.po'],
    '*'       => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/locales/*.po'],
    '_auto'   => 1,
    '_decode' => 1,
};

sub register {
    my ($self, $app) = @_;

    $app->helper(server_name => sub { return [split(/\./, Sys::Hostname::hostname)]->[0] });

    $app->helper(
        l => sub {
            my $c = shift;

            state %handles;
            my $language = $c->stash->{language} || 'EN';

            $handles{$language} //= Locale::Maketext::ManyPluralForms->get_handle(lc $language);

            die("could not build locale for language $language") unless $handles{$language};

            return $handles{$language}->maketext(@_);
        });

    $app->helper(
        country_code => sub {
            my $c = shift;

            return $c->stash->{country_code} if $c->stash->{country_code};

            my $client_country = lc($c->req->headers->header('CF-IPCOUNTRY') || 'aq');
            # Note: xx means there is no country data
            $client_country = 'aq' if ($client_country eq 'xx');

            return $c->stash->{country_code} = $client_country;
        });

    $app->helper(
        landing_company_name => sub {
            my $c = shift;

            # JP users have a different trading page, and default to Japanese translations.
            # Eventually we would handle this through branding, but for now we have a specific
            # override - the landing_company_name here should match the $landing_company->short
            # string.
            $c->stash->{landing_company_name} ||= 'japan' if $c->country_code eq 'jp';

            return $c->stash->{landing_company_name};
        });

    $app->helper(
        new_error => sub {
            my $c = shift;
            my ($msg_type, $code, $message, $details) = @_;

            my $error = {
                code    => $code,
                message => $message
            };
            $error->{details} = $details if $details;

            return {
                msg_type => $msg_type,
                error    => $error,
            };
        });

    # read it once, and share between workers
    my $chronicle_cfg = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/chronicle.yml');
    my $ws_redis_cfg  = YAML::XS::LoadFile($ENV{BOM_TEST_WS_REDIS}         // '/etc/rmg/ws-redis.yml');
    my $redis_url     = sub {
        my $cfg = shift;
        my ($host, $port, $password) = @{$cfg}{qw/host port password/};
        "redis://" . ($password ? "x:$password\@" : "") . "$host:$port";
    };
    my $chronicle_redis_url = $redis_url->($chronicle_cfg->{read});
    my $ws_redis_url        = $redis_url->($ws_redis_cfg->{write});

    my @redises = ([ws_redis_master => $redis_url->($ws_redis_cfg->{write})], [ws_redis_slave => $redis_url->($ws_redis_cfg->{read})],);

    for my $redis_info (@redises) {
        my ($helper_name, $redis_url) = @$redis_info;
        $app->helper(
            $helper_name => sub {
                state $redis = do {
                    my $redis = Mojo::Redis2->new(url => $redis_url);
                    $redis->on(
                        error => sub {
                            my ($self, $err) = @_;
                            $app->log->warn("redis error: $err");
                            warn("redis error: $err");
                        });
                    $redis;
                };
                return $redis;
            });
    }

    # one redis connection (Mojo::Redis2 instance) per worker, i.e. shared among multiple clients, connected to
    # the same worker
    $app->helper(
        shared_redis => sub {
            state $redis = do {
                my $redis = Mojo::Redis2->new(url => $chronicle_redis_url);
                $redis->on(
                    error => sub {
                        my ($self, $err) = @_;
                        $app->log->warn("redis error: $err");
                    });
                $redis->on(
                    message => sub {
                        my ($self, $msg, $channel) = @_;

                        return warn "Misuse shared_redis: the message on channel '$channel' is not expected"
                            if $channel !~ /^FEED::/;

                        my $shared_info = $app->redis_connections($channel);
                        Binary::WebSocketAPI::v3::Wrapper::Streamer::process_realtime_events($shared_info, $msg, $channel);
                    });
                $redis;
            };
            return $redis;
        });

    my $redis_connections = {};
    $app->helper(
        redis_connections => sub {
            my ($c, $key) = @_;
            return $redis_connections->{$key} //= {};
        });

    $app->helper(
        redis => sub {
            my $c = shift;

            if (not $c->stash->{redis}) {
                my $redis = Mojo::Redis2->new(url => $chronicle_redis_url);
                $redis->on(
                    error => sub {
                        my ($self, $err) = @_;
                        warn("error: $err");
                    });
                $redis->on(
                    message => sub {
                        my ($self, $msg, $channel) = @_;

                        Binary::WebSocketAPI::v3::Wrapper::Streamer::process_transaction_updates($c, $msg)
                            if $channel =~ /^TXNUPDATE::transaction_/;
                    });
                $c->stash->{redis} = $redis;
            }
            return $c->stash->{redis};
        });

    $app->helper(
        redis_pricer => sub {
            my $c = shift;

            if (not $c->stash->{redis_pricer}) {
                state $url_pricers = do {
                    my $cf = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};
                    my $url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");
                    $url->userinfo('dummy:' . $cf->{password}) if $cf->{password};
                    $url;
                };

                my $redis_pricer = Mojo::Redis2->new(url => $url_pricers);
                $redis_pricer->on(
                    error => sub {
                        my ($self, $err) = @_;
                        warn("error: $err");
                    });
                $redis_pricer->on(
                    message => sub {
                        my ($self, $msg, $channel) = @_;

                        Binary::WebSocketAPI::v3::Wrapper::Pricer::process_pricing_events($c, $msg, $channel);
                    });
                $c->stash->{redis_pricer} = $redis_pricer;
            }
            return $c->stash->{redis_pricer};
        });

    return;
}

1;

package Binary::WebSocketAPI::Plugins::Helpers;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use feature "state";
use Sys::Hostname;
use YAML::XS;
use Guard;
use Scalar::Util ();
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;

use Locale::Maketext::ManyPluralForms {
    'EN'      => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/en.po'],
    '*'       => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/locales/*.po'],
    '_auto'   => 1,
    '_decode' => 1,
};

sub register {
    my ($self, $app) = @_;

    $app->helper(server_name => sub { return [split(/\./, Sys::Hostname::hostname)]->[0] });

    # Weakrefs to active $c instances
    $app->helper(
        active_connections => sub {
            my $app = shift->app;
            return $app->{_binary_connections} //= {};
        });

    # for storing various statistic data
    $app->helper(
        stat => sub {
            my $app = shift->app;
            return $app->{_binary_introspection_stats} //= {};
        });

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

    # for 'website_status' with 'subscribe' option, see also bin/clients_notify.pl
    my $ws_redis_master_on_message = sub {
        my ($self, $msg, $channel) = @_;
        if ($channel eq "NOTIFY::broadcast::channel") {
            my $shared_info = $app->redis_connections($channel);
            Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($shared_info, $msg, $channel);
        }
    };

    my @redises = ([
            ws_redis_master => $redis_url->($ws_redis_cfg->{write}),
            on_message      => $ws_redis_master_on_message
        ],
        [ws_redis_slave => $redis_url->($ws_redis_cfg->{read})],
    );

    my $redis_on_error_sub = sub {
        my ($redis, $err) = @_;
        $app->log->warn("redis error: $err");
        $app->stat->{redis_errors}++;
    };

    for my $redis_info (@redises) {
        my ($helper_name, $redis_url, $on_message, $on_msg_sub) = @$redis_info;
        $app->helper(
            $helper_name => sub {
                state $redis = do {
                    my $redis = Mojo::Redis2->new(url => $redis_url);
                    $redis->on(error      => $redis_on_error_sub);
                    $redis->on(message    => $on_msg_sub) if $on_message;
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
                $redis->on(error      => $redis_on_error_sub);
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

    my $pricing_subscriptions = {};
    $app->helper(
        pricing_subscriptions => sub {
            my ($c, $key) = @_;
            return $pricing_subscriptions unless $key;

            return $pricing_subscriptions->{$key} if $pricing_subscriptions->{$key};

            my $subscribe = Binary::WebSocketAPI::v3::PricingSubscription->new(channel_name => $key);
            $pricing_subscriptions->{$key} = $subscribe;
            Scalar::Util::weaken($pricing_subscriptions->{$key});
            return $pricing_subscriptions->{$key};
        });

    $app->helper(
        redis => sub {
            my $c = shift;

            if (not $c->stash->{redis}) {
                my $redis = Mojo::Redis2->new(url => $chronicle_redis_url);
                $redis->on(error      => $redis_on_error_sub);
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
            ### Instance::Redis
            $c->stash->{redis_pricer} = pricer_write();
            return $c->stash->{redis_pricer};
        });

    $app->helper(
        proposal_array_collector => sub {
            my $c = shift;
            Scalar::Util::weaken(my $weak_c = $c);
            # send proposal_array stream messages collected from appropriate proposal streams
            my $proposal_array_loop_id_keeper;
            $proposal_array_loop_id_keeper = Mojo::IOLoop->recurring(
                1,
                sub {
                    # It's possible for the client to disconnect before we're finished.
                    # If that happens, make sure we clean up but don't attempt to process any further.
                    my $c = $weak_c;
                    unless ($c && $c->tx) {
                        Mojo::IOLoop->remove($proposal_array_loop_id_keeper);
                        return;
                    }

                    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') or do {
                        Mojo::IOLoop->remove($proposal_array_loop_id_keeper);
                        return;
                    };

                    my %proposal_array;
                    for my $pa_uuid (keys %{$proposal_array_subscriptions}) {
                        my $sub = $proposal_array_subscriptions->{$pa_uuid};
                        for my $i (0 .. $#{$sub->{seq}}) {
                            my $uuid     = $sub->{seq}[$i];
                            my $barriers = $sub->{args}{barriers}[$i];
                            # Bail out early if we have any streams without a response yet
                            my $proposal = $sub->{proposals}{$uuid} or return;
                            for my $contract_type (keys %$proposal) {
                                for my $price (@{$proposal->{$contract_type}}) {
                                    # Ensure we have barriers
                                    if ($price->{error}) {
                                        $price->{error}{details}{barrier} //= $barriers->{barrier};
                                        $price->{error}{details}{barrier2} //= $barriers->{barrier2} if exists $barriers->{barrier2};
                                        $price->{error}{message} = delete $price->{error}{message_to_client}
                                            if exists $price->{error}{message_to_client};
                                    }
                                    push @{$proposal_array{$contract_type}}, $price;
                                }
                            }
                        }

                        my $results = {
                            proposal_array => {
                                proposals => \%proposal_array,
                                id        => $pa_uuid,
                            },
                            echo_req => $proposal_array_subscriptions->{$pa_uuid}{args},
                            msg_type => 'proposal_array',
                        };
                        $c->send({json => $results}, {args => $proposal_array_subscriptions->{$pa_uuid}{args}});
                    }
                });
        });

    return;
}

1;

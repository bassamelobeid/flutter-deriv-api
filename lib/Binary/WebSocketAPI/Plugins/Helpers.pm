package Binary::WebSocketAPI::Plugins::Helpers;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use feature "state";

use Sys::Hostname;
use Scalar::Util ();
use IO::Async::Loop;
use curry;

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Instance::Redis qw| ws_redis_master redis_pricer shared_redis |;

use Locale::Maketext::ManyPluralForms {
    'EN'      => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/en.po'],
    '*'       => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/locales/*.po'],
    '_auto'   => 1,
    '_decode' => 1,
};

# List of all country codes supported as VPN address overrides. Anything in
# this list can be passed as `X-Client-Country` by the Electron application
# and we will honour that country in preference to the Cloudflare country
# headers.
use constant ELECTRON_SUPPORTED_COUNTRIES => qw(id);

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
            my ($content, @params) = @_;

            return '' unless $content;

            state %handles;
            my $language = $c->stash->{language} || 'EN';

            $handles{$language} //= Locale::Maketext::ManyPluralForms->get_handle(lc $language);

            die("could not build locale for language $language") unless $handles{$language};
            my @texts = ();
            if (ref $content eq 'ARRAY') {
                return '' unless scalar @$content;
                my $content_copy = [@$content];    # save original
                                                   # first one is always text string
                push @texts, shift @$content_copy;
                # followed by parameters
                foreach my $elm (@$content_copy) {
                    # some params also need localization (longcode)
                    if (ref $elm eq 'ARRAY' and scalar @$elm) {
                        push @texts, $handles{$language}->maketext(@$elm);
                    } else {
                        push @texts, $elm;
                    }
                }
            } else {
                @texts = ($content, @params);
            }

            return $handles{$language}->maketext(@texts);
        });

    # Indicates which country codes we allow our Electron app to
    # request. Extend this if you want to provide desktop app
    # services in other areas.
    my %allowed_app_countries = map { ; $_ => $_ } ELECTRON_SUPPORTED_COUNTRIES;
    $app->helper(
        country_code => sub {
            my $c = shift;

            return $c->stash->{country_code} if $c->stash->{country_code};

            my $client_country =
                lc($allowed_app_countries{$c->req->headers->header('X-Client-Country') // ''} || $c->req->headers->header('CF-IPCOUNTRY') || 'aq');
            # Note: xx means there is no country data
            $client_country = 'aq' if ($client_country eq 'xx');

            return $c->stash->{country_code} = $client_country;
        });

    $app->helper(
        landing_company_name => sub {
            my $c = shift;

            return $c->stash->{landing_company_name};
        });

    $app->helper(
        new_error => sub {
            shift;
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

    for my $redis_name (qw(ws_redis_master redis_pricer shared_redis)) {
        $app->helper(
            $redis_name => sub {
                return Binary::WebSocketAPI::v3::Instance::Redis->$redis_name;
            });
    }

    my $pricing_subscriptions = {};
    $app->helper(
        pricing_subscriptions => sub {
            my (undef, $key) = @_;
            return $pricing_subscriptions unless $key;

            return $pricing_subscriptions->{$key} if $pricing_subscriptions->{$key};

            my $subscribe = Binary::WebSocketAPI::v3::PricingSubscription->new(channel_name => $key);
            $pricing_subscriptions->{$key} = $subscribe;
            Scalar::Util::weaken($pricing_subscriptions->{$key});
            return $pricing_subscriptions->{$key};
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
                    unless ($weak_c && $weak_c->tx) {
                        Mojo::IOLoop->remove($proposal_array_loop_id_keeper);
                        return;
                    }

                    my $proposal_array_subscriptions = $weak_c->stash('proposal_array_subscriptions') or do {
                        Mojo::IOLoop->remove($proposal_array_loop_id_keeper);
                        return;
                    };

                    my @pa_keys = keys %{$proposal_array_subscriptions};
                    PA_LOOP:
                    for my $pa_uuid (@pa_keys) {
                        my %proposal_array;
                        my $sub = $proposal_array_subscriptions->{$pa_uuid};
                        for my $i (0 .. $#{$sub->{seq}}) {
                            my $uuid = $sub->{seq}[$i];
                            unless ($uuid) {
                                # this case is hold in `proposal_array` - for some reasons `_pricing_channel_for_ask`
                                # did not created uuid for one of the `proposal_array`'s `proposal` calls
                                # subscription anyway is broken - so remove it
                                # see sub proposal_array for details
                                # error messge is already sent by `response` RPC hook.
                                Binary::WebSocketAPI::v3::Wrapper::System::_forget_proposal_array($weak_c, $pa_uuid);
                                delete $proposal_array_subscriptions->{$pa_uuid};
                                next PA_LOOP;
                            }
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
                            echo_req     => $proposal_array_subscriptions->{$pa_uuid}{args},
                            msg_type     => 'proposal_array',
                            subscription => {id => $pa_uuid},
                        };
                        $weak_c->send({json => $results}, {args => $proposal_array_subscriptions->{$pa_uuid}{args}});
                    }
                    $weak_c->stash('proposal_array_subscriptions' => $proposal_array_subscriptions)
                        if scalar(@pa_keys) != scalar(keys %{$proposal_array_subscriptions});
                    return;
                });
        });

    # This is stored as a singleton in IO::Async::Loop, so ->new is cheap to call
    $app->helper(loop => sub { IO::Async::Loop->new });

    return;
}

1;

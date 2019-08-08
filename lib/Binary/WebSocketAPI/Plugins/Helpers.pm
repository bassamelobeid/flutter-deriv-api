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
use Binary::WebSocketAPI::v3::Instance::Redis qw| ws_redis_master redis_pricer shared_redis redis_transaction |;

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

    for my $redis_name (qw(ws_redis_master redis_pricer shared_redis redis_transaction)) {
        $app->helper(
            $redis_name => sub {
                return Binary::WebSocketAPI::v3::Instance::Redis->$redis_name;
            });
    }

    # This is stored as a singleton in IO::Async::Loop, so ->new is cheap to call
    $app->helper(loop => sub { IO::Async::Loop->new });

    return;
}

1;

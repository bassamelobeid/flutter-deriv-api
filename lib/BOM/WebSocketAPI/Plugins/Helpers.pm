package BOM::WebSocketAPI::Plugins::Helpers;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use Data::Validate::IP;
use Sys::Hostname;

sub register {
    my ($self, $app) = @_;

    $app->helper(
        client_ip => sub {
            my $c = shift;

            return $c->stash->{client_ip} if $c->stash->{client_ip};
            if (my $ip = $c->req->headers->header('x-forwarded-for')) {
                ($c->stash->{client_ip}) =
                    grep { Data::Validate::IP::is_ipv4($_) }
                    split(/,\s*/, $ip);
            }
            return $c->stash->{client_ip};
        });

    $app->helper(
        server_name => sub {
            my $c = shift;

            return [split(/\./, Sys::Hostname::hostname)]->[0];
        });

    $app->helper(
        country_code => sub {
            my $c = shift;

            return $c->stash->{country_code} if $c->stash->{country_code};
            my $client_country = lc($c->req->headers->header('CF-IPCOUNTRY') || 'aq');
            $client_country = 'aq' if ($client_country eq 'xx');
            my $ip = $c->client_ip;
            if (($ip =~ /^99\.99\.99\./) or ($ip =~ /^192\.168\./) or ($ip eq '127.0.0.1')) {
                $client_country = 'aq';
            }
            return $c->stash->{country_code} = $client_country;
        });

    $app->helper(
        l => sub {
            my $c = shift;

            my $lh = BOM::Platform::Context::I18N::handle_for($c->stash('language'))
                || die("could not build locale for language " . $c->stash('language'));

            return $lh->maketext(@_);
        });

    $app->helper(
        new_error => sub {
            my $c = shift;
            my ($msg_type, $code, $message, $details) = @_;

            my $error = {
                code    => $code,
                message => $message
            };
            $error->{details} = $details if (keys %$details);

            return {
                msg_type => $msg_type,
                error    => $error,
            };
        });

    return;
}

1;

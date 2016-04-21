package BOM::WebSocketAPI::Plugins::Helpers;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use Sys::Hostname;
use BOM::Platform::Context qw/ localize /;

sub register {
    my ($self, $app) = @_;

    $app->helper(
        country_code => sub {
            my $c = shift;

            return $c->stash->{country_code} if $c->stash->{country_code};

            my $client_country = lc($c->req->headers->header('CF-IPCOUNTRY') || 'aq');
            $client_country = 'aq' if ($client_country eq 'xx');

            return $c->stash->{country_code} = $client_country;
        });

    $app->helper(server_name => sub { return [split(/\./, Sys::Hostname::hostname)]->[0] });
    $app->helper(l => sub { return localize(@_) });

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

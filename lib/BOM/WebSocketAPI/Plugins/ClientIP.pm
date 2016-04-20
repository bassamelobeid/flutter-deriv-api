package BOM::WebSocketAPI::Plugins::ClientIP;

use base 'Mojolicious::Plugin';

use strict;
use warnings;
use Data::Validate::IP;

sub register {
    my ($self, $app) = @_;

    $app->helper(
        client_ip => sub {
            my $c = shift;

            return $c->stash->{client_ip} if $c->stash->{client_ip};

            if (my $forwarder_for = $c->req->headers->header('x-forwarded-for')) {
                ($c->stash->{client_ip}) =
                    grep { Data::Validate::IP::is_ipv4($_) }
                    split(/,\s*/, $forwarder_for);
            }

            return $c->stash->{client_ip} if $c->stash->{client_ip};

            if (
                not $ENV{'REMOTE_ADDR'}
                # REMOTE_ADDR not set for whatever reason
                or $ENV{'REMOTE_ADDR'} =~ /\Q127.0.0.1\E/
                # client IP showing up as same as server IP
                or ($ENV{'SERVER_ADDR'} and $ENV{'REMOTE_ADDR'} eq $ENV{'SERVER_ADDR'}))
            {
                # extract client IP from X-Forwarded-For
                if (my $forwarder_for = $ENV{'HTTP_X_FORWARDED_FOR'}) {
                    ($c->stash->{client_ip}) =
                        grep {
                               Data::Validate::IP::is_ipv4($_)
                            && !Data::Validate::IP::is_private_ipv4($_)
                            && !Data::Validate::IP::is_loopback_ipv4($_)
                        }
                        split(/,\s*/, $forwarder_for);
                }
            }

            return $c->stash->{client_ip} ||= $ENV{'REMOTE_ADDR'} || '';
        });
    return;
}

1;

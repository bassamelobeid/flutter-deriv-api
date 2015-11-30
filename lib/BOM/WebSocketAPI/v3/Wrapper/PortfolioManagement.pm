package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::PortfolioManagement;

sub sell {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::PortfolioManagement::sell($c->stash('client'), $c->stash('source'), $args);
    if (exists $response->{error}) {
        if (exists $response->{error}->{message}) {
            $c->app->log->info($response->{error}->{message});
        }
        return $c->new_error('landing_company', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type => 'sell',
            sell     => $response
        };
    }
    return;
}

1;

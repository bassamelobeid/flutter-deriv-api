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
        return $c->new_error('sell', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type => 'sell',
            sell     => $response
        };
    }
    return;
}

sub portfolio {
    my ($c, $args) = @_;

    return {
        msg_type  => 'portfolio',
        portfolio => BOM::WebSocketAPI::v3::PortfolioManagement::portfolio($c->stash('client'))};
}

sub buy {
    my ($c, $args) = @_;

    my $contract_parameters = BOM::WebSocketAPI::v3::Wrapper::System::forget_one $c, $args->{buy}
        or return $c->new_error('buy', 'InvalidContractProposal', $c->l("Unknown contract proposal"));

    my $response = BOM::WebSocketAPI::v3::PortfolioManagement::buy($client, $c->stash('source'), $contract_parameters, $args);
    if (exists $response->{error}) {
        $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
        return $c->new_error('buy', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type => 'buy',
            buy      => $response
        };
    }
}

1;

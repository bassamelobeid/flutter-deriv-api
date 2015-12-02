package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use JSON;

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

    my $response = BOM::WebSocketAPI::v3::PortfolioManagement::buy($c->stash('client'), $c->stash('source'), $contract_parameters, $args);
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

sub proposal_open_contract {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my @fmbs = ();
    if ($args->{contract_id}) {
        @fmbs = grep { $args->{contract_id} eq $_->id } $client->open_bets;
    } else {
        @fmbs = $client->open_bets;
    }

    # need to do it in wrapper as we subscribe to feed_channel and is implementation specific
    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            my $id = BOM::WebSocketAPI::v3::MarketDiscovery::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                'proposal_open_contract:' . JSON::to_json($args));

            # library would only return contract parameters
            my $latest = BOM::WebSocketAPI::v3::PortfolioManagement::get_bid($fmb->short_code, $fmb->id, $client->currency);

            $c->send({
                    json => {
                        msg_type               => 'proposal_open_contract',
                        echo_req               => $args,
                        proposal_open_contract => {
                            id => $id,
                            %$latest
                        }}});
        }
    } else {
        return {
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
}

1;

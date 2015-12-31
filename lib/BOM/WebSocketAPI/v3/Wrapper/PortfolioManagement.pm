package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use JSON;

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub portfolio {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'portfolio',
        sub {
            my $response = shift;
            return {
                msg_type  => 'portfolio',
                portfolio => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
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

    # don't touch args as we send them in echo_req
    my $details = {%$args};
    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            $details->{short_code}  = $fmb->short_code;
            $details->{contract_id} = $fmb->id;
            $details->{currency}    = $client->currency;
            my $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                'proposal_open_contract:' . JSON::to_json($details));
            send_proposal($c, $id, $args, $details);
        }
    } else {
        return {
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
}

sub send_proposal {
    my ($c, $id, $args, $details) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_bid',
        sub {
            my $response = shift;
            return {
                msg_type               => 'proposal_open_contract',
                proposal_open_contract => {
                    id => $id,
                    %$response
                }};
        },
        {
            args        => $args,
            short_code  => $details->{short_code},
            contract_id => $details->{contract_id},
            currency    => $details->{currency}});
    return;
}

1;

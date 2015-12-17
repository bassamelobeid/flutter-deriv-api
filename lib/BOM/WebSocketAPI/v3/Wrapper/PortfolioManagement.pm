package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use JSON;

use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::Contract;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub portfolio {
    my ($c, $args) = @_;

    return {
        msg_type  => 'portfolio',
        portfolio => BOM::RPC::v3::PortfolioManagement::portfolio($c->stash('client'))};
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
            # these keys needs to be deleted from args (check send_proposal)
            # populating here cos we stash them in redis channel
            $args->{short_code}  = $fmb->short_code;
            $args->{contract_id} = $fmb->id;
            $args->{currency}    = $client->currency;
            my $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                'proposal_open_contract:' . JSON::to_json($args));
            send_proposal($c, $id, $args);
        }
    } else {
        return {
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
}

sub send_proposal {
    my ($c, $id, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_bid',
        sub {
            my $response = shift;

            return {
                msg_type => 'proposal_open_contract',
                echo_req => $args,
                (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                proposal_open_contract => {
                    id => $id,
                    %$response
                }};
        },
        {args => $args});
    return;
}

1;

package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use JSON;

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::System;

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

    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            # these keys needs to be deleted from args (check send_proposal)
            # populating here cos we stash them in redis channel
            $args->{short_code}  = $fmb->short_code;
            $args->{contract_id} = $fmb->id;
            $args->{currency}    = $client->currency;
            my $id;
            if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
                $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                    'proposal_open_contract:' . JSON::to_json($args), $args);
            }
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

    my $details = {%$args};
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_bid',
        sub {
            my $response = shift;
            if ($response) {
                if (exists $response->{error}) {
                    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                    return $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
                } elsif (exists $response->{is_expired} and $response->{is_expired} eq '1') {
                    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                }
                return {
                    msg_type               => 'proposal_open_contract',
                    proposal_open_contract => {
                        $id ? id => $id : (),
                        %$response
                    }};
            } else {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
            }
        },
        {
            short_code  => delete $details->{short_code},
            contract_id => delete $details->{contract_id},
            currency    => delete $details->{currency},
            args        => $details
        });
    return;
}

1;

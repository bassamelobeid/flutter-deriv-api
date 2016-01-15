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
            if (exists $response->{error}) {
                return $c->new_error('portfolio', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type  => 'portfolio',
                    portfolio => $response,
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            source         => $c->stash('source')});
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
            my $details = {%$args};
            # these keys needs to be deleted from args (check send_proposal)
            # populating here cos we stash them in redis channel
            $details->{short_code}  = $fmb->short_code;
            $details->{contract_id} = $fmb->id;
            $details->{currency}    = $client->currency;
            my $id;
            if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
                $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'subscribe', $fmb->underlying_symbol,
                    'proposal_open_contract:' . JSON::to_json($details), $details);
            }
            send_proposal($c, $id, $details);
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
                    msg_type => 'proposal_open_contract',
                    proposal_open_contract => {$id ? (id => $id) : (), %$response}};
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

sub sell_expired {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'sell_expired',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('sell_expired', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type     => 'sell_expired',
                    sell_expired => $response,
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            source         => $c->stash('source')});
    return;
}

1;

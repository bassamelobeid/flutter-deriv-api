package BOM::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use JSON;

use BOM::RPC::v3::Accounts;
use BOM::WebSocketAPI::Websocket_v3;

sub payout_currencies {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'payout_currencies',
        sub {
            my $response = shift;
            return {
                msg_type          => 'payout_currencies',
                payout_currencies => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub landing_company {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'landing_company',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('landing_company', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type        => 'landing_company',
                    landing_company => $response
                };
            }
        },
        {args => $args});
    return;
}

sub landing_company_details {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'landing_company_details',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('landing_company_details', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type                => 'landing_company_details',
                    landing_company_details => $response,
                };
            }
        },
        {args => $args});
    return;
}

sub statement {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'statement',
        sub {
            my $response = shift;
            return {
                msg_type  => 'statement',
                statement => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub profit_table {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'profit_table',
        sub {
            my $response = shift;
            return {
                msg_type     => 'profit_table',
                profit_table => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub get_account_status {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_account_status',
        sub {
            my $response = shift;
            return {
                msg_type           => 'get_account_status',
                get_account_status => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub change_password {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'change_password',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('change_password', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type        => 'change_password',
                    change_password => $response->{status}};
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            token_type     => $c->stash('token_type'),
            cs_email       => $r->website->config->get('customer_support.email'),
            client_ip      => $r->client_ip
        });
    return;
}

sub cashier_password {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'cashier_password',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('cashier_password', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type         => 'cashier_password',
                    cashier_password => $response->{status}};
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            cs_email       => $r->website->config->get('customer_support.email'),
            client_ip      => $r->client_ip
        });
    return;
}

sub get_settings {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_settings',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('get_settings', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type     => 'get_settings',
                    get_settings => $response
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            language       => $c->stash('request')->language
        });
    return;
}

sub set_settings {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'set_settings',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('set_settings', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type     => 'set_settings',
                    set_settings => $response->{status}};
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            website_name   => $r->website->display_name,
            cs_email       => $r->website->config->get('customer_support.email'),
            client_ip      => $r->client_ip,
            user_agent     => $c->req->headers->header('User-Agent'),
            language       => $r->language
        });
    return;
}

sub get_self_exclusion {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_self_exclusion',
        sub {
            my $response = shift;
            return {
                msg_type           => 'get_self_exclusion',
                get_self_exclusion => $response
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub set_self_exclusion {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'set_self_exclusion',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                my $err = $c->new_error('set_self_exclusion', $response->{error}->{code}, $response->{error}->{message_to_client});
                $err->{error}->{field} = $response->{error}->{details} if (exists $response->{error}->{details});
                return $err;
            } else {
                return {
                    msg_type           => 'set_self_exclusion',
                    set_self_exclusion => $response->{status}};
            }
        },
        {
            args             => $args,
            client_loginid   => $c->stash('loginid'),
            cs_email         => $c->stash('request')->website->config->get('customer_support.email'),
            compliance_email => $c->app_config->compliance->email
        });
    return;
}

sub balance {
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    if ($client->default_account and exists $args->{subscribe}) {
        my $redis             = $c->stash('redis');
        my $channel           = 'TXNUPDATE::balance_' . $client->default_account->id;
        my $subscriptions     = $c->stash('subscribed_channels') // {};
        my $already_subsribed = $subscriptions->{$channel};

        if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
            if (!$already_subsribed) {
                $redis->subscribe([$channel], sub { });
                $subscriptions->{$channel} = 1;
                $c->stash('subscribed_channels', $subscriptions);
            } else {
                warn "Client is already subscribed to the channel $channel; ignoring";
            }
        }
        if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
            if ($already_subsribed) {
                $redis->unsubscribe([$channel], sub { });
                delete $subscriptions->{$channel};
            } else {
                warn "Client isn't subscribed to the channel $channel, but trying to unsubscribe; ignoring";
            }
        }
    }

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'balance',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('balance', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'balance',
                    balance  => $response
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub send_realtime_balance {
    my ($c, $message) = @_;

    my $client = $c->stash('client');
    my $args   = $c->stash('args');

    my $payload = JSON::from_json($message);

    $c->send({
            json => {
                msg_type => 'balance',
                echo_req => $args,
                (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                balance => BOM::RPC::v3::Accounts::send_realtime_balance($client, $payload)}}) if $c->tx;
    return;
}

sub api_token {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'api_token',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('api_token', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type  => 'api_token',
                    api_token => $response
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

1;


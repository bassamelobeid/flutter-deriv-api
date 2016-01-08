package BOM::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

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

    my $id;
    my $client = $c->stash('client');
    if ($client and $client->default_account) {
        if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
            if (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_balance_channel($c, 'subscribe', $client->default_account->id, $args)) {
                return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance updates.'));
            }
        }
    }

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'balance',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                return $c->new_error('balance', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'balance',
                    balance => {$id ? (id => $id) : (), %$response}};
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

sub send_realtime_balance {
    my ($c, $message) = @_;

    my $args = {};
    my $channel;
    my $client        = $c->stash('client');
    my $subscriptions = $c->stash('subscribed_channels');
    if ($subscriptions) {
        $channel = first { m/TXNUPDATE::balance/ } keys %$subscriptions;
        $args = ($channel and exists $subscriptions->{$channel}->{args}) ? $subscriptions->{$channel}->{args} : {};
    }

    if ($client) {
        my $payload = JSON::from_json($message);
        $c->send({
                json => {
                    msg_type => 'balance',
                    $args ? (echo_req => $args) : (),
                    ($args and exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                    balance => {
                        loginid  => $client->loginid,
                        currency => $client->default_account ? $client->default_account->currency_code : '',
                        balance  => $payload->{balance_after},
                        ($channel and exists $subscriptions->{$channel}->{uuid}) ? (id => $subscriptions->{$channel}->{uuid}) : ()}}}) if $c->tx;
    } else {
        if ($channel and exists $subscriptions->{$channel}->{account_id}) {
            BOM::WebSocketAPI::v3::Wrapper::Streamer::_balance_channel($c, 'unsubscribe', $subscriptions->{$channel}->{account_id}, $args);
        }
    }
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

sub tnc_approval {
    my ($c, $args) = @_;

    my $r          = $c->stash('request');
    my $app_config = $c->app_config;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'tnc_approval',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('tnc_approval', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type     => 'tnc_approval',
                    tnc_approval => $response->{status}};
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
        });

    return;
}

1;


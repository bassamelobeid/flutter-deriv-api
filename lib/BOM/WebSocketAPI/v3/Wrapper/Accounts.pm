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
            args  => $args,
            token => $c->stash('token')});
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
            if (exists $response->{error}) {
                return $c->new_error('statement', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type  => 'statement',
                    statement => $response,
                };
            }
        },
        {
            args   => $args,
            token  => $c->stash('token'),
            source => $c->stash('source')});
    return;
}

sub profit_table {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'profit_table',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('profit_table', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type     => 'profit_table',
                    profit_table => $response,
                };
            }
        },
        {
            args   => $args,
            token  => $c->stash('token'),
            source => $c->stash('source')});
    return;
}

sub get_account_status {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_account_status',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('get_account_status', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type           => 'get_account_status',
                    get_account_status => $response->{status},
                };
            }
        },
        {
            args  => $args,
            token => $c->stash('token'),
        });
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
            args       => $args,
            token      => $c->stash('token'),
            token_type => $c->stash('token_type'),
            client_ip  => $r->client_ip
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
            args      => $args,
            token     => $c->stash('token'),
            client_ip => $r->client_ip
        });
    return;
}

sub reset_password {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'reset_password',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('reset_password', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type         => 'reset_password',
                    reset_password   => $response->{status}};
            }
        },
        {args => $args});
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
            args     => $args,
            token    => $c->stash('token'),
            language => $c->stash('request')->language
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
            args         => $args,
            token        => $c->stash('token'),
            website_name => $r->website->display_name,
            client_ip    => $r->client_ip,
            user_agent   => $c->req->headers->header('User-Agent'),
            language     => $r->language
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
            if (exists $response->{error}) {
                return $c->new_error('get_self_exclusion', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type           => 'get_self_exclusion',
                    get_self_exclusion => $response
                };
            }
        },
        {
            args  => $args,
            token => $c->stash('token'),
        });
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
            args  => $args,
            token => $c->stash('token'),
        });
    return;
}

sub balance {
    my ($c, $args) = @_;

    my $id;
    my $account_id = $c->stash('account_id');
    if (    $account_id
        and exists $args->{subscribe}
        and $args->{subscribe} eq '1'
        and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, 'balance', $args)))
    {
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance updates.'));
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
            args  => $args,
            token => $c->stash('token'),
        });
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
            args       => $args,
            token      => $c->stash('token'),
            account_id => $c->stash('account_id'),
        });
    return;
}

sub tnc_approval {
    my ($c, $args) = @_;

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
            args  => $args,
            token => $c->stash('token'),
        });

    return;
}

sub login_history {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'login_history',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('login_history', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type      => 'login_history',
                    login_history => $response->{records}};
            }
        },
        {
            args  => $args,
            token => $c->stash('token'),
        });

    return;
}

sub set_account_currency {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'set_account_currency',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('set_account_currency', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type             => 'set_account_currency',
                    set_account_currency => $response->{status}};
            }
        },
        {
            args     => $args,
            token    => $c->stash('token'),
            currency => $args->{set_account_currency}});

    return;
}

sub set_financial_assessment {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'set_financial_assessment',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('set_financial_assessment', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type                 => 'set_financial_assessment',
                    set_financial_assessment => $response
                };
            }
        },
        {
            args  => $args,
            token => $c->stash('token')});

    return;
}

sub get_financial_assessment {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_financial_assessment',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('get_financial_assessment', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type                 => 'get_financial_assessment',
                    get_financial_assessment => $response
                };
            }
        },
        {
            args  => $args,
            token => $c->stash('token')});

    return;
}

1;

package BOM::WebSocketAPI::v3::Wrapper::Cashier;

use strict;
use warnings;

use BOM::RPC::v3::Cashier;
use BOM::WebSocketAPI::Websocket_v3;

sub get_limits {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = $c->app_config->payments->withdrawal_limits->$landing_company;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_limits',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('get_limits', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type   => 'get_limits',
                    get_limits => $response,
                };
            }
        },
        {
            args           => $args,
            client_loginid => $client->loginid,
            for_days       => $wl_config->for_days,
            limit_for_days => $wl_config->limit_for_days,
            lifetime_limit => $wl_config->lifetime_limit
        });
    return;
}

sub paymentagent_list {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'paymentagent_list',
        sub {
            my $response = shift;
            return {
                msg_type          => 'paymentagent_list',
                paymentagent_list => $response,
            };
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            language       => $c->stash('request')->language
        });
    return;
}

sub paymentagent_withdraw {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'paymentagent_withdraw',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
                return $c->new_error('paymentagent_withdraw', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type              => 'paymentagent_withdraw',
                    paymentagent_withdraw => $response,
                };
            }
        },
        {
            args                       => $args,
            client_loginid             => $c->stash('loginid'),
            is_payment_suspended       => $app_config->system->suspend->payments,
            is_payment_agent_suspended => $app_config->system->suspend->payment_agents,
            cs_email                   => $c->stash('request')->website->config->get('customer_support.email'),
            payments_email             => $app_config->payments->email
        });
    return;
}

sub paymentagent_transfer {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Cashier::paymentagent_transfer($c->stash('client'), $c->app_config, $c->stash('request')->website, $args);
    if (exists $response->{error}) {
        $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
        return $c->new_error('paymentagent_transfer', $response->{error}->{code}, $response->{error}->{message_to_client});
    }

    return {
        msg_type              => 'paymentagent_transfer',
        paymentagent_transfer => $response->{status},
    };
}

sub transfer_between_accounts {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Cashier::transfer_between_accounts({
        client     => $c->stash('client'),
        app_config => $c->app_config,
        website    => $c->stash('request')->website,
        args       => $args
    });
    if (exists $response->{error}) {
        $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
        return $c->new_error('transfer_between_accounts', $response->{error}->{code}, $response->{error}->{message_to_client});
    }

    return {
        msg_type                  => 'transfer_between_accounts',
        transfer_between_accounts => $response->{status},
        (exists $response->{accounts}) ? (accounts => $response->{accounts}) : (),
    };
}

sub topup_virtual {
    my ($c, $args) = @_;

    my $res = BOM::RPC::v3::Cashier::topup_virtual({
        client     => $c->stash('client'),
        app_config => $c->app_config,
    });
    if (exists $res->{error}) {
        $c->app->log->info($res->{error}->{message}) if (exists $res->{error}->{message});
        return $c->new_error('topup_virtual', $res->{error}->{code}, $res->{error}->{message_to_client});
    }

    return {
        msg_type      => 'topup_virtual',
        topup_virtual => $res,
    };
}

1;

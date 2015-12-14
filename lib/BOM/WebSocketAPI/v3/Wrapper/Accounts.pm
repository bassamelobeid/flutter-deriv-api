package BOM::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use JSON;

use BOM::RPC::v3::Accounts;

sub payout_currencies {
    my $c = shift;

    return {
        msg_type          => 'payout_currencies',
        payout_currencies => BOM::RPC::v3::Accounts::payout_currencies($c->stash('account')),
    };
}

sub landing_company {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        'BOM::RPC::v3::Accounts::landing_company',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('landing_company', $response->{error}->{code}, $response->{error}->{message_to_client});
            }
            return {
                msg_type        => 'landing_company',
                landing_company => $response
            };
        },
        $args
    );
    return;
}

sub landing_company_details {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Accounts::landing_company_details($args);
    if (exists $response->{error}) {
        return $c->new_error('landing_company_details', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type                => 'landing_company_details',
            landing_company_details => $response
        };
    }
}

sub statement {
    my ($c, $args) = @_;

    return {
        msg_type => 'statement',
        statement => BOM::RPC::v3::Accounts::statement($c->stash('account'), $args)};
}

sub profit_table {
    my ($c, $args) = @_;

    return {
        msg_type => 'profit_table',
        profit_table => BOM::RPC::v3::Accounts::profit_table($c->stash('client'), $args)};
}

sub get_account_status {
    my ($c, $args) = @_;

    return {
        msg_type           => 'get_account_status',
        get_account_status => BOM::RPC::v3::Accounts::get_account_status($c->stash('client'))};
}

sub change_password {
    my ($c, $args) = @_;

    my $r        = $c->stash('request');
    my $response = BOM::RPC::v3::Accounts::change_password(
        $c->stash('client'),
        $c->stash('token_type'),
        $r->website->config->get('customer_support.email'),
        $r->client_ip, $args
    );

    if (exists $response->{error}) {
        return $c->new_error('change_password', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type        => 'change_password',
            change_password => $response->{status}};
    }
    return;
}

sub cashier_password {
    my ($c, $args) = @_;

    my $r = $c->stash('request');
    my $response =
        BOM::RPC::v3::Accounts::cashier_password($c->stash('client'), $r->website->config->get('customer_support.email'), $r->client_ip, $args);

    if (exists $response->{error}) {
        return $c->new_error('cashier_password', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type         => 'cashier_password',
            cashier_password => $response->{status},
        };
    }
    return;
}

sub get_settings {
    my ($c, $args) = @_;

    return {
        msg_type => 'get_settings',
        get_settings => BOM::RPC::v3::Accounts::get_settings($c->stash('client'), $c->stash('request')->language)};
}

sub set_settings {
    my ($c, $args) = @_;

    my $r = $c->stash('request');

    my $response = BOM::RPC::v3::Accounts::set_settings($c->stash('client'), $r->website, $r->client_ip, $c->req->headers->header('User-Agent'),
        $r->language, $args);

    if (exists $response->{error}) {
        return $c->new_error('set_settings', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type     => 'set_settings',
            set_settings => $response->{status}};
    }

    return;
}

sub get_self_exclusion {
    my ($c, $args) = @_;
    return {
        msg_type           => 'get_self_exclusion',
        get_self_exclusion => BOM::RPC::v3::Accounts::get_self_exclusion($c->stash('client'))};
}

sub set_self_exclusion {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Accounts::set_self_exclusion(
        $c->stash('client'),
        $c->stash('request')->website->config->get('customer_support.email'),
        $c->app_config->compliance->email, $args
    );
    if (exists $response->{error}) {
        my $err = $c->new_error('set_self_exclusion', $response->{error}->{code}, $response->{error}->{message_to_client});
        $err->{error}->{field} = $response->{error}->{details} if (exists $response->{error}->{details});
        return $err;
    } else {
        return {
            msg_type           => 'set_self_exclusion',
            set_self_exclusion => $response->{status}};
    }

    return;
}

sub balance {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    if ($client->default_account) {
        my $redis   = $c->stash('redis');
        my $channel = ['TXNUPDATE::balance_' . $client->default_account->id];

        if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
            $redis->subscribe($channel, sub { });
        }
        if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
            $redis->unsubscribe($channel, sub { });
        }
    }

    return {
        msg_type => 'balance',
        balance  => BOM::RPC::v3::Accounts::balance($client)};
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
                balance => BOM::RPC::v3::Accounts::send_realtime_balance($client, $payload)}}) if $c->tx;
    return;
}

sub api_token {
    my ($c, $args) = @_;

    my $response = BOM::RPC::v3::Accounts::api_token($c->stash('client'), $args);
    if (exists $response->{error}) {
        return $c->new_error('api_token', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type  => 'api_token',
            api_token => $response,
        };
    }
}

1;


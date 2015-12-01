package BOM::WebSocketAPI::v3::Wrapper::Cashier;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Cashier;

sub get_limits {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = $c->app_config->payments->withdrawal_limits->$landing_company;

    my $response = BOM::WebSocketAPI::v3::Cashier::get_limits($client, $wl_config);

    if (exists $response->{error}) {
        return $c->new_error('get_limits', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type   => 'get_limits',
            get_limits => $response
        };
    }
}

sub paymentagent_list {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::Cashier::paymentagent_list($c->stash('client'), $c->stash('request')->language, $args);

    return {
        msg_type          => 'paymentagent_list',
        paymentagent_list => $response
    };
}

sub paymentagent_withdraw {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::Cashier::paymentagent_withdraw($c->stash('client'), $c->app_config, $c->stash('request')->website, $args);
    if (exists $response->{error}) {
        $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
        return $c->new_error('paymentagent_withdraw', $response->{error}->{code}, $response->{error}->{message_to_client});
    }

    return {
        msg_type              => 'paymentagent_withdraw',
        paymentagent_withdraw => $response->{status},
    };
}

sub paymentagent_transfer {
    my ($c, $args) = @_;

    my $response = BOM::WebSocketAPI::v3::Cashier::paymentagent_transfer($c->stash('client'), $c->app_config, $c->stash('request')->website, $args);
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

    my $response = BOM::WebSocketAPI::v3::Cashier::transfer_between_accounts({
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
    };
}

1;

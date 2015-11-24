package BOM::WebSocketAPI::v3::Wrapper::Cashier;

use strict;
use warnings;

sub get_limits {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = $c->app_config->payments->withdrawal_limits->$landing_company;

    my $response = BOM::WebSocketAPI::v3::Cashier::get_limits($client, $wl_config);

    if (exists $response->{error}) {
        return $c->new_error('get_limits', $response->{error}->{code}, $response->{error}->{message});
    } else {
        return {
            msg_type   => 'get_limits',
            get_limits => $response
        };
    }
}

sub paymentagent_list {
    my ($c, $args) = @_;

    my $client  = $c->stash('client');
    my $request = $c->stash('request');

    return {
        msg_type => 'paymentagent_list',
        paymentagent_list => {%BOM::WebSocketAPI::v3::Cashier::paymentagent_list ($client, $request->language, $request->website)}};
}

1;

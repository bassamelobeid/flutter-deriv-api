package BOM::API::Payment::Account;

use Moo;
with 'BOM::API::Payment::Role::Plack';

use BOM::Platform::Client;
use BOM::Platform::Data::Persistence::DataMapper::Account;
use Try::Tiny;

sub account_GET {
    my $c      = shift;
    my $env    = $c->env;
    my $client = $c->user;

    if (my $err = $c->validate('currency_code')) {
        return $c->status_bad_request($err);
    }

    my $account = $client->default_account || do {
        return $c->throw(500, "No account for client $client");
    };

    my $currency_code = $c->request_parameters->{currency_code};

    if ($currency_code ne $account->currency_code) {
        return $c->status_bad_request("No $currency_code account for client $client");
    }

    my $limit = $client->get_limit({
        for      => 'account_balance',
        currency => $currency_code
    });

    return {
        client_loginid => $client->loginid,
        currency_code  => $currency_code,
        balance        => sprintf("%0.2f", $account->balance),
        limit          => sprintf("%0.2f", $limit),
    };
}

no Moo;

1;

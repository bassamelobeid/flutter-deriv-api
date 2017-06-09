package BOM::API::Payment::Account;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Client::Account;
use Format::Util::Numbers qw/financialrounding/;

sub account_GET {
    my $c      = shift;
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

    return {
        client_loginid => $client->loginid,
        currency_code  => $currency_code,
        balance        => financialrounding('amount', $currency_code, $account->balance),
        limit          => financialrounding('amount', $currency_code, $client->get_limit_for_account_balance),
    };
}

no Moo;

1;

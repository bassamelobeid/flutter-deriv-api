package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use List::MoreUtils qw(any);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Locale;

sub new_account_virtual {
    my ($c, $args) = @_;

    my $acc = BOM::Platform::Account::Virtual::create_account({details => $args});

    if (my $err_code = $acc->{error}) {
        return $c->new_error('account', $err_code, BOM::Platform::Locale::error_map()->{$err_code});
    }

    my $client  = $acc->{client};
    my $account = $client->default_account->load;

    return {
        msg_type => 'account',
        account  => {
            client_id => $client->loginid,
            currency  => $account->currency_code,
            balance   => $account->balance,
        }};
}

1;

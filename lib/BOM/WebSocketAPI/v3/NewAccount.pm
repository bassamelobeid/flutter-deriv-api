package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use BOM::Platform::Account::Virtual;

sub virtual {
    my ($c, $args) = @_;

    my $acc = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
        }});
    my $client = $acc->{client};
    my $account = $client->default_account->load;

    my $result = {
        loginid  => $client->loginid,
        currency => $account->currency_code,
        balance  => $account->balance,
    };

    return {
        echo_req  => $args,
        msg_type  => 'account',
        account   => $result,
    };
}

1;

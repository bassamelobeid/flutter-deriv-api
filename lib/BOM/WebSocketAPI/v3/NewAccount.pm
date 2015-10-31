package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use List::MoreUtils qw(any);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Locale;

sub new_account_virtual {
    my ($c, $args) = @_;

    my $allowed_countries = BOM::Platform::Locale::generate_residence_countries_list();
    unless (any { not exists $_->{disabled} and $_->{value} and $args->{residence} eq $_->{value} } @$allowed_countries) {
        return {
            echo_req => $args,
            msg_type => 'account',
            error    => {
                message => localize("Sorry, our service is not available for your country of residence"),
                code    => 'ResidenceInvalid',
            }};
    }

    my $acc     = BOM::Platform::Account::Virtual::create_account({details => $args});
    my $client  = $acc->{client};
    my $account = $client->default_account->load;

    my $result = {
        client_id => $client->loginid,
        currency  => $account->currency_code,
        balance   => $account->balance,
    };

    return {
        echo_req => $args,
        msg_type => 'account',
        account  => $result,
    };
}

1;

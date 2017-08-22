package BOM::Platform::Account::Real::subaccount;

use strict;
use warnings;

use BOM::Platform::Account::Real::default;

sub create_sub_account {
    my $args = shift;
    my ($from_client, $user) = @{$args}{'from_client', 'user'};

    # we need to mark new client to be sub_account_of master client
    $args->{details}->{sub_account_of} = $from_client->loginid;
    my $details = $args->{details};
    if (my $error = BOM::Platform::Account::Real::default::validate($args)) {
        return $error;
    }

    my $register = BOM::Platform::Account::Real::default::register_client($details);
    return $register if ($register->{error});

    return BOM::Platform::Account::Real::default::after_register_client({
        client  => $register->{client},
        user    => $user,
        details => $details,
        ip      => $args->{ip},
        country => $args->{country},
    });
}

# as some omnibus partners don't want to provide their client details so we
# need to populate details based on omnibus partner/master account
sub populate_details {
    my ($master_client, $params) = @_;

    my $populated_params = {};

    if ($params) {
        foreach my $key (BOM::Platform::Account::Real::default::get_account_fields()) {
            if ($key eq 'secret_answer') {
                # as we cannot decode secret answer of client so we store dummy value
                # for secret answer, we will not need it as its managed my master account
                $populated_params->{$key} = $params->{$key} // 'dummy';
            } else {
                $populated_params->{$key} = $params->{$key} // $master_client->$key;
            }
        }
    }

    return $populated_params;
}

1;

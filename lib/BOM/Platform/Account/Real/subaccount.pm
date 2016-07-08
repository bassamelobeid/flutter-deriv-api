package BOM::Platform::Account::Real::subaccount;

use strict;
use warnings;

use BOM::Platform::Account::Real::default;

sub create_sub_account {
    my $args = shift;

    $args->{details} = _populate_details($args->{from_client}, $args->{details});

    my ($user, $details) = @{$args}{'user', 'details'};

    if (my $error = BOM::Platform::Account::Real::default::validate($args)) {
        return $error;
    }
    my $register = BOM::Platform::Account::Real::default::register_client($details);
    return $register if ($register->{error});

    return BOM::Platform::Account::Real::default::after_register_client({
        client  => $register->{client},
        user    => $user,
        details => $details,
    });
}

# as some traders don't want to provide their client details so we
# need to populate details based on traders/master account
sub _populate_details {
    my ($master_client, $params) = @_;

    my $populated_params = {};

    if ($params) {
        foreach my $key (BOM::Platform::Account::Real::default::get_account_fields()) {
            if ($key eq 'secret_answer') {
                # as we cannot decode secret answer of client so we store dummy value
                # for secret answer, we will not need it as its managed my master account
                $populated_params->{$key} = $params->{$key} // 'dummy';
            } elsif ($key eq 'first_name' or $key eq 'last_name') {
                # we need to have firstname, lastname unique so append time to loginid
                # of master account in case no name is provided
                $populated_params->{$key} = $params->{$key} // $master_client->loginid . time;
            } else {
                $populated_params->{$key} = $params->{$key} // $master_client->$key;
            }
        }
    }

    return $populated_params;
}

1;

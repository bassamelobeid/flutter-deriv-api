package BOM::Platform::Account::Real::subaccount;

use strict;
use warnings;

use BOM::Platform::Account::Real::default;

sub create_sub_account {
    my $args = shift;
    my ($from_client, $user, $details) = @{$args}{'from_client', 'user', 'details'};

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

1;

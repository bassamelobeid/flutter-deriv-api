package BOM::RPC::v3::Mt5::NewAccount;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);
use BOM::Mt5::User;

sub new_account_mt5 {
    my $params = shift;

    my $client = $params->{client};
    my $args = $params->{args};

    my $account_type = delete $args->{account_type};

    my $group;
    if ($account_type eq 'real_money') {
        $group = 'real\real';
    } elsif ($account_type eq 'demo') {
        $group = 'demo\demoforex';
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccountType',
                message_to_client => localize('Invalid account type.')
            });
    }

    $args->{group} = $group;
    my $user = BOM::Mt5::User::create_user($args);

    if ($user->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5CreateUserError',
                message_to_client => $user->{error}
            });
    }

    my $login = $user->{login};
    my $balance = 0;

    # funds in Virtual money
    if ($account_type eq 'demo') {
        $balance = 5000;
        my $status = BOM::Mt5::User::virtual_deposit($login, $balance);

        # deposit failed
        if ($status->{error}) {
            $balance = 0;
        }
    }

    return {
        login           => $user->{login},
        account_type    => $account_type,
        balance         => $balance
    };
}


1;

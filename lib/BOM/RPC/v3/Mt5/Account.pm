package BOM::RPC::v3::Mt5::Account;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);
use BOM::Platform::User;
use BOM::Mt5::User;
use Locale::Country::Extra;

sub mt5_new_account {
    my $params = shift;

    my $client       = $params->{client};
    my $args         = $params->{args};
    my $account_type = delete $args->{account_type};

    my $group;
    if ($account_type eq 'demo') {
        $group = 'demo\demoforex';
    } elsif ( grep { $account_type eq $_ } qw(costarica iom malta maltainvest japan) ) {
        $group = 'real\\' . $account_type;
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccountType',
                message_to_client => localize('Invalid account type.')});
    }
    $args->{group} = $group;

    my $country_name = Locale::Country::Extra->new()->country_from_code($args->{country});
    $args->{country} = $country_name if ($country_name);

    my $status = BOM::Mt5::User::create_user($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5CreateUserError',
                message_to_client => $status->{error}});
    }
    my $mt5_login = $status->{login};

    my $user = BOM::Platform::User->new({email => $client->email});
    # eg: MT5 login: 1000, we store MT1000
    $user->add_loginid({loginid => 'MT' . $mt5_login});
    $user->save;

    my $balance = 0;
    # funds in Virtual money
    if ($account_type eq 'demo') {
        $balance = 5000;
        $status  = BOM::Mt5::User::deposit({
            login   => $mt5_login,
            amount  => $balance,
            comment => 'Binary MT5 Virtual Money deposit.'
        });

        # deposit failed
        if ($status->{error}) {
            $balance = 0;
        }
    }

    return {
        login        => $mt5_login,
        account_type => $account_type,
        balance      => $balance
    };
}

sub mt5_get_settings {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $login eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $settings = BOM::Mt5::User::get_user($login);
    if ($settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5GetUserError',
                message_to_client => $settings->{error}});
    }

    my $country_code = Locale::Country::Extra->new()->code_from_country($settings->{country});
    $settings->{country} = $country_code if ($country_code);

    return $settings;
}

sub mt5_set_settings {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $login eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $country_name = Locale::Country::Extra->new()->country_from_code($args->{country});
    $args->{country} = $country_name if ($country_name);

    my $settings = BOM::Mt5::User::update_user($args);
    if ($settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5UpdateUserError',
                message_to_client => $settings->{error}});
    }
    return $settings;
}

sub mt5_password_check {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $login eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $status = BOM::Mt5::User::password_check($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5PasswordCheckError',
                message_to_client => $status->{error}});
    }
    return 1;
}

sub mt5_password_change {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $login eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $status = BOM::Mt5::User::password_change($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5PasswordChangeError',
                message_to_client => $status->{error}});
    }
    return 1;
}

sub deposit {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $source = $params->{source};

    my $from_binary = $args->{from_binary};
    my $to_mt5      = $args->{to_mt5};
    my $amount      = $args->{amount};

    if ($amount <= 0) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'Mt5DepositError',
            message_to_client => localize("Amount must be greater than zero."),
        });
    }

    # MT5 login or binary loginid not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $to_mt5 eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }
    if (not grep { $from_binary eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $comment = "Transfer from $from_binary to MT5 account $to_mt5.";

    # withdraw from Binary a/c
    my $fmClient = BOM::Platform::Client->new({loginid => $from_binary});
    my $fmAccount = $fmClient->set_default_account('USD');

    my ($fmPayment) = $fmAccount->add_payment({
        amount               => -$amount,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $from_binary,
        remark               => $comment,
    });
    my ($fmTrx) = $fmPayment->add_transaction({
        account_id    => $fmAccount->id,
        amount        => -$amount,
        staff_loginid => $from_binary,
        referrer_type => 'payment',
        action_type   => 'withdrawal',
        quantity      => 1,
        source        => $source,
    });
    $fmAccount->save(cascade => 1);
    $fmPayment->save(cascade => 1);

    # deposit to MT5 a/c
    my $status = BOM::Mt5::User::deposit({
        login   => $to_mt5,
        amount  => $amount,
        comment => $comment
    });

    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5DepositError',
                message_to_client => $status->{error}});
    }
    return 1;
}

sub withdrawal {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $source = $params->{source};

    my $from_mt5  = $args->{from_mt5};
    my $to_binary = $args->{to_binary};
    my $amount    = $args->{amount};

    if ($amount <= 0) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'Mt5WithdrawalError',
            message_to_client => localize("Amount must be greater than zero."),
        });
    }

    # MT5 login or binary loginid not belongs to user
    my $user = BOM::Platform::User->new({email => $client->email});
    if (not grep { 'MT' . $from_mt5 eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }
    if (not grep { $to_binary eq $_->loginid } ($user->loginid)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $comment = "Transfer from MT5 account $from_mt5 to $to_binary.";

    # withdraw from MT5 a/c
    my $status = BOM::Mt5::User::withdrawal({
        login   => $from_mt5,
        amount  => $amount,
        comment => $comment
    });

    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Mt5WithdrawalError',
                message_to_client => $status->{error}});
    }

    # deposit to Binary a/c
    my $toClient = BOM::Platform::Client->new({loginid => $to_binary});
    my $toAccount = $toClient->set_default_account('USD');

    my ($toPayment) = $toAccount->add_payment({
        amount               => $amount,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $to_binary,
        remark               => $comment,
    });
    my ($toTrx) = $toPayment->add_transaction({
        account_id    => $toAccount->id,
        amount        => $amount,
        staff_loginid => $to_binary,
        referrer_type => 'payment',
        action_type   => 'deposit',
        quantity      => 1,
        source        => $source,
    });
    $toAccount->save(cascade => 1);
    $toPayment->save(cascade => 1);

    return 1;
}

1;

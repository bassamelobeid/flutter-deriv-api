package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

use List::Util qw(any);
use Try::Tiny;
use Locale::Country::Extra;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::Platform::Context qw (localize);
use BOM::Platform::User;
use BOM::MT5::User;
use BOM::Database::Transaction;

sub mt5_login_list {
    my $params = shift;
    my $client = $params->{client};

    my @array;
    foreach (BOM::Platform::User->new({email => $client->email})->mt5_logins) {
        $_ =~ /^MT(\d+)$/;
        push @array, {login => $1};
    }
    return \@array;
}

sub mt5_new_account {
    my $params = shift;

    my $client       = $params->{client};
    my $args         = $params->{args};
    my $account_type = delete $args->{account_type};

    my $group;
    if ($account_type eq 'demo') {
        $group = 'demo\demoforex';
    } elsif (
        any {
            $account_type eq $_
        }
        qw(vanuatu costarica iom malta maltainvest japan)
        )
    {
        # only enable vanuatu for now, so default all real a/c type to vanuatu
        $group        = 'real\vanuatu';
        $account_type = 'vanuatu';

        # only CR fully authenticated client can open MT real a/c
        unless ($client->landing_company->short eq 'costarica' and $client->client_fully_authenticated) {
            return BOM::RPC::v3::Utility::permission_error();
        }
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccountType',
                message_to_client => localize('Invalid account type.')});
    }

    # client can have only 1 MT demo & 1 MT real a/c
    my $user = BOM::Platform::User->new({email => $client->email});

    my $acc = {};
    foreach ($user->mt5_logins) {
        $_ =~ /^MT(\d+)$/;
        my $login = $1;

        my $setting = mt5_get_settings({
                client => $client,
                args   => {login => $login}});

        if ($setting->{group} =~ /^demo\\/) {
            $acc->{demo} = $login;
        } elsif ($setting->{group} =~ /^real\\(\w+)$/) {
            $acc->{$1} = $login;
        }
    }

    if (exists $acc->{$account_type}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5CreateUserError',
                message_to_client => localize('You already have a [_1] account [_2]', $account_type, $acc->{$account_type})});
    }

    $args->{group} = $group;

    my $country_name = Locale::Country::Extra->new()->country_from_code($args->{country});
    $args->{country} = $country_name if ($country_name);

    my $status = BOM::MT5::User::create_user($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5CreateUserError',
                message_to_client => $status->{error}});
    }
    my $mt5_login = $status->{login};

    # eg: MT5 login: 1000, we store MT1000
    $user->add_loginid({loginid => 'MT' . $mt5_login});
    $user->save;

    my $balance = 0;
    # funds in Virtual money
    if ($account_type eq 'demo') {
        $balance = 5000;
        $status  = BOM::MT5::User::deposit({
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

sub _check_mt_login {
    my ($client, $mt_login) = @_;

    my $user = BOM::Platform::User->new({email => $client->email});
    my $mt_login = 'MT' . $mt_login;

    return (any { $mt_login eq $_->loginid } ($user->loginid));
}

sub mt5_get_settings {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $login);

    my $settings = BOM::MT5::User::get_user($login);
    if ($settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5GetUserError',
                message_to_client => $settings->{error}});
    }

    my $country_code = Locale::Country::Extra->new()->code_from_country($settings->{country});
    $settings->{country} = $country_code if ($country_code);

    return $settings;
}

sub _mt5_is_real_account {
    my ($client, $mt_login) = @_;

    my $settings = mt5_get_settings({
        client => $client,
        args   => {login => $mt_login},
    });

    return ($settings->{group} // '') =~ /^real\\/;
}

sub mt5_set_settings {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $login);

    my $country_code = $args->{country};
    my $country_name = Locale::Country::Extra->new()->country_from_code($country_code);
    $args->{country} = $country_name if ($country_name);

    my $settings = BOM::MT5::User::update_user($args);
    if ($settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5UpdateUserError',
                message_to_client => $settings->{error}});
    }

    $settings->{country} = $country_code;
    return $settings;
}

sub mt5_password_check {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $login);

    my $status = BOM::MT5::User::password_check($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5PasswordCheckError',
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
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $login);

    my $status = BOM::MT5::User::password_change($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5PasswordChangeError',
                message_to_client => $status->{error}});
    }
    return 1;
}

sub mt5_deposit {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $source = $params->{source};

    my $fm_loginid = $args->{from_binary};
    my $to_mt5     = $args->{to_mt5};
    my $amount     = $args->{amount};

    my $error_sub = sub {
        my ($msg_client, $msg) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'MT5DepositError',
            message_to_client => localize('There was an error processing the request.') . ' ' . $msg_client,
            ($msg) ? (message => $msg) : (),
        });
    };

    if ($amount <= 0) {
        return $error_sub->(localize("Deposit amount must be greater than zero."));
    }

    # MT5 login or binary loginid not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $to_mt5);
    return BOM::RPC::v3::Utility::permission_error() unless (any { $fm_loginid eq $_->loginid } ($user->loginid));

    my $fm_client = BOM::Platform::Client->new({loginid => $fm_loginid});

    # only for real money account
    if ($fm_client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }
    if (not _mt5_is_real_account($fm_client, $to_mt5)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    if ($fm_client->currency ne 'USD') {
        return $error_sub->(localize('Your account [_1] has a different currency [_2] than USD.', $fm_loginid, $fm_client->currency));
    }
    if ($fm_client->get_status('disabled')) {
        return $error_sub->(localize('Your account [_1] was disabled.', $fm_loginid));
    }
    if ($fm_client->get_status('cashier_locked') || $fm_client->documents_expired) {
        return $error_sub->(localize('Your account [_1] cashier section was locked.', $fm_loginid));
    }

    # withdraw from Binary a/c
    if (not BOM::Database::Transaction->freeze_client($fm_loginid)) {
        return $error_sub->(localize('If this error persists, please contact customer support.'),
            "Account stuck in previous transaction $fm_loginid");
    }

    my $withdraw_error;
    try {
        $fm_client->validate_payment(
            currency => 'USD',
            amount   => -$amount,
        );
    }
    catch {
        $withdraw_error = $_;
    };

    if ($withdraw_error) {
        return $error_sub->(
            BOM::RPC::v3::Cashier::__client_withdrawal_notes({
                    client => $fm_client,
                    amount => $amount,
                    error  => $withdraw_error
                }));
    }

    my $comment   = "Transfer from $fm_loginid to MT5 account $to_mt5.";
    my $account   = $fm_client->set_default_account('USD');
    my ($payment) = $account->add_payment({
        amount               => -$amount,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $fm_loginid,
        remark               => $comment,
    });
    my ($txn) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => -$amount,
        staff_loginid => $fm_loginid,
        referrer_type => 'payment',
        action_type   => 'withdrawal',
        quantity      => 1,
        source        => $source,
    });
    $account->save(cascade => 1);
    $payment->save(cascade => 1);

    # deposit to MT5 a/c
    my $status = BOM::MT5::User::deposit({
        login   => $to_mt5,
        amount  => $amount,
        comment => $comment
    });

    if ($status->{error}) {
        return $error_sub->($status->{error});
    }

    BOM::Database::Transaction->unfreeze_client($fm_loginid);
    return {
        status                => 1,
        binary_transaction_id => $txn->id
    };
}

sub mt5_withdrawal {
    my $params = shift;
    my $client = $params->{client};
    my $args   = $params->{args};
    my $source = $params->{source};

    my $fm_mt5     = $args->{from_mt5};
    my $to_loginid = $args->{to_binary};
    my $amount     = $args->{amount};

    my $error_sub = sub {
        my ($msg_client, $msg) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'MT5WithdrawalError',
            message_to_client => localize('There was an error processing the request.') . ' ' . $msg_client,
            ($msg) ? (message => $msg) : (),
        });
    };

    if ($amount <= 0) {
        return $error_sub->(localize("Withdrawal amount must be greater than zero."));
    }

    # MT5 login or binary loginid not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_mt_login($client, $fm_mt5);
    return BOM::RPC::v3::Utility::permission_error() unless (any { $to_loginid eq $_->loginid } ($user->loginid));

    my $to_client = BOM::Platform::Client->new({loginid => $to_loginid});

    # only for real money account
    if ($to_client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }
    if (not _mt5_is_real_account($to_client, $fm_mt5)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    if ($to_client->currency ne 'USD') {
        return $error_sub->(localize('Your account [_1] has a different currency [_2] than USD.', $to_loginid, $to_client->currency));
    }

    if ($to_client->get_status('disabled')) {
        return $error_sub->(localize('Your account [_1] was disabled.', $to_loginid));
    }
    if ($to_client->get_status('cashier_locked') || $to_client->documents_expired) {
        return $error_sub->(localize('Your account [_1] cashier section was locked.', $to_loginid));
    }

    if (not BOM::Database::Transaction->freeze_client($to_loginid)) {
        return $error_sub->(localize('If this error persists, please contact customer support.'),
            "Account stuck in previous transaction $to_loginid");
    }

    my $comment = "Transfer from MT5 account $fm_mt5 to $to_loginid.";

    # withdraw from MT5 a/c
    my $status = BOM::MT5::User::withdrawal({
        login   => $fm_mt5,
        amount  => $amount,
        comment => $comment
    });

    if ($status->{error}) {
        return $error_sub->($status->{error});
    }

    # deposit to Binary a/c
    my $account = $to_client->set_default_account('USD');
    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $to_loginid,
        remark               => $comment,
    });
    my ($txn) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $to_loginid,
        referrer_type => 'payment',
        action_type   => 'deposit',
        quantity      => 1,
        source        => $source,
    });
    $account->save(cascade => 1);
    $payment->save(cascade => 1);

    BOM::Database::Transaction->unfreeze_client($to_loginid);
    return {
        status                => 1,
        binary_transaction_id => $txn->id
    };
}

1;

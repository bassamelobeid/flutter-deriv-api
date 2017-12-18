package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

use Guard;
use YAML::XS;
use List::Util qw(any first);
use Try::Tiny;
use File::ShareDir;
use Locale::Country::Extra;
use Brands;
use WebService::MyAffiliates;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::Platform::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::User;
use BOM::MT5::User;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime;
use BOM::Platform::Email;
use BOM::Transaction;

common_before_actions qw(auth);

rpc mt5_login_list => sub {
    my $params = shift;
    my $client = $params->{client};

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $setting;

    my @array;
    foreach (BOM::Platform::User->new({email => $client->email})->mt5_logins) {
        $_ =~ /^MT(\d+)$/;
        my $login = $1;
        my $acc = {login => $login};

        $setting = mt5_get_settings({
                client => $client,
                args   => {login => $login}});
        if (ref $setting eq 'HASH' && $setting->{group}) {
            $acc->{group} = $setting->{group};
        }

        push @array, $acc;
    }
    return \@array;
};

# limit number of requests to once per minute
sub _throttle {
    my $loginid = shift;
    my $key     = 'MT5ACCOUNT::THROTTLE::' . $loginid;

    return 1 if BOM::Platform::RedisReplicated::redis_read()->get($key);

    BOM::Platform::RedisReplicated::redis_write()->set($key, 1, 'EX', 60);

    return 0;
}

rpc mt5_new_account => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my ($client, $args) = @{$params}{qw/client args/};
    my $account_type     = delete $args->{account_type};
    my $mt5_account_type = delete $args->{mt5_account_type} // '';
    my $brand            = Brands->new(name => request()->brand);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidAccountType',
            message_to_client => localize('Invalid account type.')}) if (not $account_type or $account_type !~ /^demo|gaming|financial$/);

    my $residence = $client->residence;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoResidence',
            message_to_client => localize('Please set your country of residence.')}) unless $residence;

    my $countries_list = $brand->countries_instance->countries_list;
    return BOM::RPC::v3::Utility::permission_error()
        unless $countries_list->{$residence};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'MT5SamePassword',
            message_to_client => localize('Investor password cannot be same as main password.')}
    ) if (($args->{mainPassword} // '') eq ($args->{investPassword} // ''));

    my $invalid_sub_type_error = BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSubAccountType',
            message_to_client => localize('Invalid sub account type.')});

    my $get_company_name = sub {
        my $type = shift;

        $type = 'mt_' . $type . '_company';
        if (defined $countries_list->{$residence}->{$type}) {
            # get MT company from countries.yml
            return $countries_list->{$residence}->{$type};
        }

        return 'none';
    };

    my ($mt_company, $group);
    if ($account_type eq 'demo') {
        # demo will have demo for financial and demo for gaming
        if ($mt5_account_type) {
            return $invalid_sub_type_error unless ($mt5_account_type =~ /^cent|standard|stp$/);

            return BOM::RPC::v3::Utility::permission_error() if (($mt_company = $get_company_name->('financial')) eq 'none');

            $group = 'demo\\' . $mt_company . '_' . $mt5_account_type;
        } else {
            return BOM::RPC::v3::Utility::permission_error() if (($mt_company = $get_company_name->('gaming')) eq 'none');
            $group = 'demo\\' . $mt_company;
        }
    } elsif ($account_type eq 'gaming' or $account_type eq 'financial') {
        # 5 Sept 2016: only CR and Champion fully authenticated client can open MT real a/c
        return BOM::RPC::v3::Utility::permission_error() if ($client->landing_company->short !~ /^costarica|champion$/);

        return BOM::RPC::v3::Utility::permission_error() if (($mt_company = $get_company_name->($account_type)) eq 'none');

        if ($account_type eq 'financial') {
            return $invalid_sub_type_error unless $mt5_account_type =~ /^cent|standard|stp$/;

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'FinancialAssessmentMandatory',
                    message_to_client => localize('Please complete financial assessment.')}) unless $client->financial_assessment();
        }

        # populate mt5 agent account associated with affiliate token
        $args->{agent} = _get_mt5_account_from_affiliate_token($client->myaffiliates_token);

        $group = 'real\\' . $mt_company;
        $group .= "_$mt5_account_type" if $account_type eq 'financial';
        $group .= "_$residence" if (first { $residence eq $_ } @{$brand->countries_with_own_mt5_group});
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'MT5CreateUserError',
            message_to_client => localize('Request too frequent. Please try again later.')}) if _throttle($client->loginid);

    # client can have only 1 MT demo & 1 MT real a/c
    my $user = BOM::Platform::User->new({email => $client->email});

    foreach my $loginid ($user->mt5_logins) {
        $loginid =~ /^MT(\d+)$/;
        my $login = $1;

        my $setting = mt5_get_settings({
                client => $client,
                args   => {login => $login}});

        if (ref $setting eq 'HASH' and ($setting->{group} // '') eq $group) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'MT5CreateUserError',
                    message_to_client => localize('You already have a [_1] account [_2]', $account_type, $login)});
        }
    }

    $args->{group} = $group;

    if ($args->{country}) {
        my $country_name = Locale::Country::Extra->new()->country_from_code($args->{country});
        $args->{country} = $country_name if ($country_name);
    }

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
        $balance = 10000;
        $status  = BOM::MT5::User::deposit({
            login   => $mt5_login,
            amount  => $balance,
            comment => 'Binary MT5 Virtual Money deposit.'
        });

        # deposit failed
        if ($status->{error}) {
            warn "MT5: deposit failed for virtual account with error " . $status->{error};
            $balance = 0;
        }
    }

    return {
        login        => $mt5_login,
        balance      => $balance,
        account_type => $account_type,
        ($mt5_account_type) ? (mt5_account_type => $mt5_account_type) : ()};
};

sub _check_logins {
    my ($client, $logins) = @_;
    my $user = BOM::Platform::User->new({email => $client->email});

    foreach my $login (@{$logins}) {
        return unless (any { $login eq $_->loginid } ($user->loginid));
    }
    return 1;
}

=head2 mt5_get_settings

    $user_mt5_settings = mt5_get_settings({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns the details of 
the MT5 user, based on the MT5 login id passed.

Takes the following (named) parameters as inputs:
    
=over 4

=item * C<params> hashref that contains:

=over 4

=item * A Client::Account object under the key C<client>.

=item * A hash reference under the key C<args> that contains the MT5 login id 
under C<login> key.

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=item * C<message_to_client> that says C<MT5 API calls are suspended.>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=item * C<message_to_client> that says C<Permission denied.>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5GetUserError>.

=item * C<message_to_client> that says C<Network error.>.

=back

=back

=item * A hashref that contains the details of the user's MT5 account.

=back

=cut

rpc mt5_get_settings => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $login]);

    my $settings = BOM::MT5::User::get_user($login);
    if (ref $settings eq 'HASH' and $settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5GetUserError',
                message_to_client => $settings->{error}});
    }

    if (my $country = $settings->{country}) {
        my $country_code = Locale::Country::Extra->new()->code_from_country($country);
        if ($country_code) {
            $settings->{country} = $country_code;
        } else {
            warn "Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra";
        }
    }

    return $settings;
};

sub _mt5_is_real_account {
    my ($client, $mt_login) = @_;

    my $settings = mt5_get_settings({
            client => $client,
            args   => {login => $mt_login}});

    return $settings if ($settings->{group} // '') =~ /^real\\/;
    return;
}

=head2 mt5_set_settings

$user_mt5_settings = mt5_set_settings({
        client  => $client,
        args    => $args
    })
    
Takes a client object and a hash reference as inputs and returns the updated details of 
the MT5 user, based on the MT5 login id passed, upon success.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A Client::Account object under the key C<client>.

=item * A hash reference under the key C<args> that contains some of the following keys:

=over 4

=item * C<login> that contains the MT5 login id.

=item * C<country> that contains the country code.

=back

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=item * C<message_to_client> that says C<MT5 API calls are suspended.>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=item * C<message_to_client> that says C<Permission denied.>.

=back

=item * Update Error

=over 4

=item * C<code> stating C<MT5UpdateUserError>.

=item * C<message_to_client> that says C<Network error.>.

=back

=back

=item * A hashref that contains the updated details of the user's MT5 account.

=back
    
=cut

rpc mt5_set_settings => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $login]);

    my $country_code = $args->{country};
    my $country_name = Locale::Country::Extra->new()->country_from_code($country_code);
    $args->{country} = $country_name if ($country_name);

    my $settings = BOM::MT5::User::update_user($args);
    if (ref $settings eq 'HASH' and $settings->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5UpdateUserError',
                message_to_client => $settings->{error}});
    }

    $settings->{country} = $country_code;
    return $settings;
};

rpc mt5_password_check => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $login]);

    my $status = BOM::MT5::User::password_check($args);
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5PasswordCheckError',
                message_to_client => $status->{error}});
    }
    return 1;
};

rpc mt5_password_change => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $login]);

    my $status = BOM::MT5::User::password_check({
            login    => $args->{login},
            password => $args->{old_password}});
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5PasswordChangeError',
                message_to_client => $status->{error}});
    }

    $status = BOM::MT5::User::password_change({
            login        => $args->{login},
            new_password => $args->{new_password}});
    if ($status->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5PasswordChangeError',
                message_to_client => $status->{error}});
    }
    return 1;
};

sub _send_email {
    my %args = @_;
    my ($loginid, $mt5_id, $amount, $action, $error) = @args{qw(loginid mt5_id amount action error)};
    my $brand = Brands->new(name => request()->brand);
    my $message =
        $action eq 'deposit'
        ? "Error happened when doing MT5 deposit after withdrawal from client account:"
        : "Error happened when doing deposit to client account after withdrawal from MT5 account:";
    return BOM::Platform::Email::send_email({
        from                  => $brand->emails('system'),
        to                    => $brand->emails('payments'),
        subject               => "MT5 $action error",
        message               => [$message, "Client login id: $loginid", "MT5 login: $mt5_id", "Amount: $amount", "error: $error"],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => $loginid,
    });
}

rpc mt5_deposit => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

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

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->system)
    {
        return $error_sub->(localize('Payments are suspended.'));
    }

    if ($amount <= 0) {
        return $error_sub->(localize("Deposit amount must be greater than zero."));
    }

    if ($amount !~ /^\d+(?:\.\d{0,2})?$/) {
        return $error_sub->(localize("Only a maximum of two decimal points are allowed for the deposit amount."));
    }

    # MT5 login or binary loginid not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $to_mt5, $fm_loginid]);

    my $fm_client = Client::Account->new({loginid => $fm_loginid});

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
    my $fm_client_db = BOM::Database::ClientDB->new({
        client_loginid => $fm_loginid,
    });
    if (not $fm_client_db->freeze) {
        return $error_sub->(localize('Please try again after one minute.'), "Account stuck in previous transaction $fm_loginid");
    }
    scope_guard {
        $fm_client_db->unfreeze;
    };

    # From the point of view of our system, we're withdrawing
    # money to deposit into MT5
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
        _send_email(
            loginid => $fm_loginid,
            mt5_id  => $to_mt5,
            amount  => $amount,
            action  => 'deposit',
            error   => $status->{error},
        );
        return $error_sub->($status->{error});
    }

    return {
        status                => 1,
        binary_transaction_id => $txn->id
    };
};

rpc mt5_withdrawal => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

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

    if ($amount !~ /^\d+(?:\.\d{0,2})?$/) {
        return $error_sub->(localize("Only a maximum of two decimal points are allowed for the withdrawal amount."));
    }

    # MT5 login or binary loginid not belongs to user
    return BOM::RPC::v3::Utility::permission_error() unless _check_logins($client, ['MT' . $fm_mt5, $to_loginid]);

    my $to_client = Client::Account->new({loginid => $to_loginid});

    # only for real money account
    if ($to_client->is_virtual) {
        return BOM::RPC::v3::Utility::permission_error();
    }
    my $settings;
    unless ($settings = _mt5_is_real_account($to_client, $fm_mt5)) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    # check for fully authenticated only if it's not gaming account
    # as of now we only support gaming for binary brand, in future if we
    # support for champion please revisit this
    if (($settings->{group} // '') !~ /^real\\costarica$/ and not $client->client_fully_authenticated) {
        return $error_sub->(localize('Please authenticate your account.'));
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

    my $to_client_db = BOM::Database::ClientDB->new({
        client_loginid => $to_loginid,
    });
    if (not $to_client_db->freeze) {
        return $error_sub->(localize('Please try again after one minute.'), "Account stuck in previous transaction $to_loginid");
    }
    scope_guard {
        $to_client_db->unfreeze;
    };

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

    return try {
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

        return {
            status                => 1,
            binary_transaction_id => $txn->id
        };
    }
    catch {
        my $error = BOM::Transaction->format_error(err => $_);
        _send_email(
            loginid => $to_loginid,
            mt5_id  => $fm_mt5,
            amount  => $amount,
            action  => 'withdraw',
            error   => $error->get_mesg,
        );
        return $error_sub->($error->{-message_to_client});
    };
};

sub _is_mt5_suspended {
    my $app_config = BOM::Platform::Runtime->instance->app_config;

    if ($app_config->system->suspend->mt5) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5APISuspendedError',
                message_to_client => localize('MT5 API calls are suspended.')});
    }
    return undef;
}

sub _get_mt5_account_from_affiliate_token {
    my $token = shift;

    if ($token) {
        my $aff = WebService::MyAffiliates->new(
            user    => BOM::Platform::Config::third_party->{myaffiliates}->{user},
            pass    => BOM::Platform::Config::third_party->{myaffiliates}->{pass},
            host    => BOM::Platform::Config::third_party->{myaffiliates}->{host},
            timeout => 10
        ) or return;

        my $user_id = $aff->get_affiliate_id_from_token($token) or return;
        my $user = $aff->get_user($user_id) or return;

        my $affiliate_variables = $user->{USER_VARIABLES}->{VARIABLE} or return;
        $affiliate_variables = [$affiliate_variables] unless ref($affiliate_variables) eq 'ARRAY';

        my ($mt5_account) = grep { $_->{NAME} eq 'mt5_account' } @$affiliate_variables;
        return $mt5_account->{VALUE} if $mt5_account;
    }

    return;
}

1;

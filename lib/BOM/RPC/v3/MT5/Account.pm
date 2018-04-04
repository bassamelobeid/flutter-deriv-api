package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

no indirect;

use Guard;
use YAML::XS;
use List::Util qw(any first);
use Try::Tiny;
use File::ShareDir;
use Locale::Country::Extra;
use Brands;
use WebService::MyAffiliates;
use Future::Utils qw(fmap1);
use Format::Util::Numbers qw/ financialrounding roundcommon/;
use Postgres::FeedDB::CurrencyConverter qw/amount_from_to_currency/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::Platform::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User;
use BOM::User::Client;
use BOM::MT5::User::Async;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime;
use BOM::Platform::Email;
use BOM::Transaction;

requires_auth();

use constant MT5_ACCOUNT_THROTTLE_KEY_PREFIX => 'MT5ACCOUNT::THROTTLE::';

# Defines the oldest data we'll allow for conversion rates, anything past this
# (including when markets are closed) will be rejected.
use constant CURRENCY_CONVERSION_MAX_AGE => 3600;

# TODO(leonerd):
#   These helpers exist mostly to coördinate the idea of error management in
#   Future-chained async RPC methods. This logic would probably be a lot neater
#   if Future failure was used to indicate RPC-level errors as well, as its
#   shortcircuiting behaviour would be useful here.

sub permission_error_future {
    return Future->done(BOM::RPC::v3::Utility::permission_error());
}

sub create_error_future {
    my ($details) = @_;
    return Future->done(BOM::RPC::v3::Utility::create_error($details));
}

# TODO(leonerd):
#   Try to neaten up the dual use of this + create_error_future(); having two
#   different functions for minor different calling styles seems silly.
sub _make_error {
    my ($error_code, $msg_client, $msg) = @_;

    my $generic_message = localize('There was an error processing the request.');
    return create_error_future({
        code              => $error_code,
        message_to_client => $msg_client
        ? $generic_message . ' ' . $msg_client
        : $generic_message,
        ($msg) ? (message => $msg) : (),
    });
}

=head2 mt5_login_list

    $mt5_logins = mt5_login_list({ client => $client })

Takes a client object and returns all possible MT5 login IDs
associated with that client. Otherwise, returns an error message indicating
that MT5 is suspended.

Takes the following (named) parameters:

=over 4

=item * C<params> hashref that contains a BOM::User::Client object under the key C<client>.

=back

Returns any of the following:

=over 4

=item * A hashref that contains the following keys:

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=item * C<message_to_client> that says C<MT5 API calls are suspended.>.

=back

=item * An arrayref that contains hashrefs. Each hashref contains:

=over 4

=item * C<login> - The MT5 loginID of the client.

=item * C<group> - (optional) The group the loginID belongs to.

=back

=cut

sub get_mt5_logins {
    my ($client, $user) = @_;

    $user ||= BOM::User->new({email => $client->email});

    my $f = fmap1 {
        shift =~ /^MT(\d+)$/;
        my $login = $1;

        return mt5_get_settings({
                client => $client,
                args   => {login => $login}}
            )->then(
            sub {
                my ($setting) = @_;

                my $acc = {login => $login};
                if (ref $setting eq 'HASH' && $setting->{group}) {
                    $acc->{group} = $setting->{group};
                }

                return Future->done($acc);
            });
    }
    foreach        => [$user->mt5_logins],
        concurrent => 4;
    # purely to keep perlcritic+perltidy happy :(
    return $f;
}

async_rpc mt5_login_list => sub {
    my $params = shift;

    my $client = $params->{client};

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    return get_mt5_logins($client)->then(
        sub {
            my (@logins) = @_;
            return Future->done(\@logins);
        });
};

# limit number of requests to once per minute
sub _throttle {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return 1 if BOM::Platform::RedisReplicated::redis_read()->get($key);

    BOM::Platform::RedisReplicated::redis_write()->set($key, 1, 'EX', 60);

    return 0;
}

# removes the database entry that limit requests to 1/minute
# returns 1 if entry was present, 0 otherwise
sub reset_throttler {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return BOM::Platform::RedisReplicated::redis_write->del($key);
}

async_rpc mt5_new_account => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my ($client, $args) = @{$params}{qw/client args/};
    my $account_type = delete $args->{account_type};

    my $invalid_account_type_error = BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidAccountType',
            message_to_client => localize('Invalid account type.')});
    return Future->done($invalid_account_type_error) if (not $account_type or $account_type !~ /^demo|gaming|financial$/);

    my $residence = $client->residence;
    return create_error_future({
            code              => 'NoResidence',
            message_to_client => localize('Please set your country of residence.')}) unless $residence;

    my $brand = Brands->new(name => request()->brand);
    my $countries_list = $brand->countries_instance->countries_list;
    return permission_error_future()
        unless $countries_list->{$residence};

    return create_error_future({
            code              => 'MT5SamePassword',
            message_to_client => localize('Investor password cannot be same as main password.')}
    ) if (($args->{mainPassword} // '') eq ($args->{investPassword} // ''));

    my $invalid_sub_type_error = BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSubAccountType',
            message_to_client => localize('Invalid sub account type.')});

    my $mt5_account_type = delete $args->{mt5_account_type} // '';
    return Future->done($invalid_sub_type_error) if ($mt5_account_type and $mt5_account_type !~ /^standard|advanced$/);

    my $manager_id = delete $args->{manager_id} // '';
    # demo account is not allowed for mamm account
    return Future->done($invalid_account_type_error) if $account_type eq 'demo';

    my $get_company_name = sub {
        my $type = shift;

        $type = 'mt_' . $type . '_company';
        # get MT company from countries.yml
        return $countries_list->{$residence}->{$type} if (defined $countries_list->{$residence}->{$type});

        return 'none';
    };

    my ($mt_company, $group);
    if ($account_type eq 'demo') {
        # demo will have demo for financial and demo for gaming
        if ($mt5_account_type) {
            return permission_error_future() if (($mt_company = $get_company_name->('financial')) eq 'none');

            $group = 'demo\\' . $mt_company . '_' . $mt5_account_type;
        } else {
            return permission_error_future() if (($mt_company = $get_company_name->('gaming')) eq 'none');
            $group = 'demo\\' . $mt_company;
        }
    } elsif ($account_type eq 'gaming' or $account_type eq 'financial') {
        # 4 Jan 2018: only CR, MLT, and Champion can open MT real a/c
        return permission_error_future() unless ($client->landing_company->short =~ /^costarica|champion|malta$/);

        return permission_error_future() if (($mt_company = $get_company_name->($account_type)) eq 'none');

        if ($account_type eq 'financial') {
            return Future->done($invalid_sub_type_error) unless $mt5_account_type;

            return create_error_future({
                    code              => 'FinancialAssessmentMandatory',
                    message_to_client => localize('Please complete financial assessment.')}) unless $client->financial_assessment();
        }

        # populate mt5 agent account from manager id if applicable
        # else get one associated with affiliate token
        $args->{agent} = $manager_id // _get_mt5_account_from_affiliate_token($client->myaffiliates_token);

        $group = 'real\\';
        if ($manager_id) {
            $group .= "${manager_id}_mamm_$account_type";
        } else {
            $group .= $mt_company;
            $group .= "_$mt5_account_type" if $account_type eq 'financial';
            $group .= "_$residence"
                if (first { $residence eq $_ } @{$brand->countries_with_own_mt5_group});
        }
    }

    return create_error_future({
            code              => 'MT5CreateUserError',
            message_to_client => localize('Request too frequent. Please try again later.')}) if _throttle($client->loginid);

    # client can have only 1 MT demo & 1 MT real a/c
    my $user = BOM::User->new({email => $client->email});

    return get_mt5_logins($client, $user)->then(
        sub {
            my (@logins) = @_;

            foreach (@logins) {
                if (($_->{group} // '') eq $group) {
                    my $login = $_->{login};

                    return create_error_future({
                            code              => 'MT5CreateUserError',
                            message_to_client => localize('You already have a [_1] account [_2].', $account_type, $login)});
                }
            }

            $args->{group} = $group;

            if ($args->{country}) {
                my $country_name = Locale::Country::Extra->new()->country_from_code($args->{country});
                $args->{country} = $country_name if ($country_name);
            }

            # TODO(leonerd): This has to nest because of the `Future->done` in the
            #   foreach loop above. A better use of errors-as-failures might avoid
            #   this.
            return BOM::MT5::User::Async::create_user($args)->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        return create_error_future({
                                code              => 'MT5CreateUserError',
                                message_to_client => $status->{error}});
                    }
                    my $mt5_login = $status->{login};

                    # eg: MT5 login: 1000, we store MT1000
                    $user->add_loginid({loginid => 'MT' . $mt5_login});
                    $user->save;

                    my $balance = 0;
                    # TODO(leonerd): This other somewhat-ugly structure implements
                    #   conditional execution of a Future-returning block. It's a bit
                    #   messy. See also
                    #     https://rt.cpan.org/Ticket/Display.html?id=124040
                    return (
                        do {
                            if ($account_type eq 'demo') {
                                # funds in Virtual money
                                $balance = 10000;
                                BOM::MT5::User::Async::deposit({
                                        login   => $mt5_login,
                                        amount  => $balance,
                                        comment => 'Binary MT5 Virtual Money deposit.'
                                    }
                                    )->on_done(
                                    sub {
                                        # TODO(leonerd): It'd be nice to turn these into failed
                                        #   Futures from BOM::MT5::User::Async also.
                                        my ($status) = @_;

                                        # deposit failed
                                        if ($status->{error}) {
                                            warn "MT5: deposit failed for virtual account with error " . $status->{error};
                                            $balance = 0;
                                        }
                                    });
                            } else {
                                Future->done;
                            }
                            }
                        )->then(
                        sub {
                            return Future->done({
                                    login        => $mt5_login,
                                    balance      => $balance,
                                    currency     => ($mt_company =~ /vanuatu|costarica|demo/ ? 'USD' : 'EUR'),
                                    account_type => $account_type,
                                    ($mt5_account_type) ? (mt5_account_type => $mt5_account_type) : ()});
                        });
                });
        });
};

sub _check_logins {
    my ($client, $logins) = @_;
    my $user = BOM::User->new({email => $client->email});

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

=item * A BOM::User::Client object under the key C<client>.

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

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5GetUserError>.

=back

=back

=item * A hashref that contains the details of the user's MT5 account.

=back

=cut

async_rpc mt5_get_settings => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return permission_error_future() unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::get_user($login)->then(
        sub {
            my ($settings) = @_;

            if (ref $settings eq 'HASH' and $settings->{error}) {
                return create_error_future({
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

            $settings->{currency} = $settings->{group} =~ /vanuatu|costarica|demo/ ? 'USD' : 'EUR';

            # we don't want to send this field back
            delete $settings->{rights};
            delete $settings->{agent};

            return Future->done($settings);
        });
};

=head2 mt5_set_settings

$user_mt5_settings = mt5_set_settings({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns the updated
details of the MT5 user, based on the MT5 login id passed, upon success.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

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

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Update Error

=over 4

=item * C<code> stating C<MT5UpdateUserError>.

=back

=back

=item * A hashref that contains the updated details of the user's MT5 account.

=back

=cut

async_rpc mt5_set_settings => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return permission_error_future() unless _check_logins($client, ['MT' . $login]);

    my $country_code = $args->{country};
    my $country_name = Locale::Country::Extra->new()->country_from_code($country_code);
    $args->{country} = $country_name if ($country_name);

    return BOM::MT5::User::Async::update_user($args)->then(
        sub {
            my ($settings) = @_;

            if (ref $settings eq 'HASH' and $settings->{error}) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'MT5UpdateUserError',
                        message_to_client => $settings->{error}});
            }

            $settings->{country} = $country_code;
            return Future->done($settings);
        });
};

=head2 mt5_password_check

    $mt5_pass_check = mt5_password_check({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful validation of the user's password.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

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

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5PasswordCheckError>.

=back

=back

=item * Returns 1, indicating successful validation.

=back

=cut

async_rpc mt5_password_check => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return permission_error_future() unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::password_check({
            login    => $args->{login},
            password => $args->{password},
            type     => $args->{password_type} // 'main'
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future({
                        code              => 'MT5PasswordCheckError',
                        message_to_client => $status->{error}});
            }
            return Future->done(1);
        });
};

=head2 mt5_password_change

    $mt5_pass_change = mt5_password_change({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful change of the user's MT5 account password.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains:

=over 4

=item * C<login> that contains the MT5 login id.

=item * C<old_password> that contains the user's current password.

=item * C<new_password> that contains the user's new password. 

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

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5PasswordChangeError>.

=back

=back

=item * Returns 1, indicating successful change.

=back

=cut

async_rpc mt5_password_change => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return permission_error_future() unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::password_check({
            login    => $login,
            password => $args->{old_password},
            type     => $args->{password_type} // 'main',
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future({
                        code              => 'MT5PasswordChangeError',
                        message_to_client => $status->{error}});
            }

            return BOM::MT5::User::Async::password_change({
                login        => $login,
                new_password => $args->{new_password},
                type         => $args->{password_type} // 'main',
            });
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future({
                        code              => 'MT5PasswordChangeError',
                        message_to_client => $status->{error}});
            }
            return Future->done(1);
        });
};

=head2 mt5_password_reset

    $mt5_pass_reset = mt5_password_reset({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful reset the user's MT5 account password.

Takes the following (named) parameters as inputs:

=over 3

=item * C<params> hashref that contains:

=over 3

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains:

=over 3

=item * C<login> that contains the MT5 login id.

=item * C<new_password> that contains the user's new password. 

=back

=back

=back

Returns any of the following:

=over 3

=item * A hashref error message that contains the following keys, based on the given error:

=over 3

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 3

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 3

=item * C<code> stating C<MT5PasswordChangeError>.

=back

=back

=item * Returns 1, indicating successful reset.

=back

=cut

async_rpc mt5_password_reset => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    my $email = BOM::Platform::Token->new({token => $args->{verification_code}})->email;

    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'mt5_password_reset')->{error}) {
        return create_error_future({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    # MT5 login not belongs to user
    return permission_error_future()
        unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::password_change({
            login        => $login,
            new_password => $args->{new_password},
            type         => $args->{password_type} // 'main',
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future({
                        code              => 'MT5PasswordChangeError',
                        message_to_client => $status->{error}});
            }

            send_email({
                    from    => Brands->new(name => request()->brand)->emails('support'),
                    to      => $email,
                    subject => localize('Your MT5 password has been reset.'),
                    message => [
                        localize(
                            'The password for your MT5 account [_1] has been reset. If this request was not performed by you, please immediately contact Customer Support.',
                            $email
                        )
                    ],
                    use_email_template    => 1,
                    email_content_is_html => 1,
                    template_loginid      => $login,
                });

            return Future->done(1);
        });
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

async_rpc mt5_deposit => sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_loginid, $to_mt5, $amount) =
        @{$args}{qw/from_binary to_mt5 amount/};

    my $error_code = 'MT5DepositError';

    return _mt5_validate_and_get_amount($client, $fm_loginid, $to_mt5, $amount, $error_code)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});

            my $mt5_amount = $response;

            # withdraw from Binary a/c
            my $fm_client_db = BOM::Database::ClientDB->new({
                client_loginid => $fm_loginid,
            });

            return _make_error($error_code, localize('Please try again after one minute.'), "Account stuck in previous transaction $fm_loginid")
                if (not $fm_client_db->freeze);

            scope_guard {
                $fm_client_db->unfreeze;
            };

            my $fm_client = BOM::User::Client->new({loginid => $fm_loginid});

            # From the point of view of our system, we're withdrawing
            # money to deposit into MT5
            my $withdraw_error;
            try {
                $fm_client->validate_payment(
                    currency => $fm_client->default_account->currency_code,
                    amount   => -$amount,
                );
            }
            catch {
                $withdraw_error = $_;
            };

            if ($withdraw_error) {
                return _make_error(
                    $error_code,
                    BOM::RPC::v3::Cashier::__client_withdrawal_notes({
                            client => $fm_client,
                            amount => $amount,
                            error  => $withdraw_error
                        }));
            }

            my $comment   = "Transfer from $fm_loginid to MT5 account $to_mt5.";
            my $account   = $fm_client->set_default_account($fm_client->currency);
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
            return BOM::MT5::User::Async::deposit({
                    login   => $to_mt5,
                    amount  => $mt5_amount,
                    comment => $comment
                }
                )->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        _send_email(
                            loginid => $fm_loginid,
                            mt5_id  => $to_mt5,
                            amount  => $amount,
                            action  => 'deposit',
                            error   => $status->{error},
                        );
                        return _make_error($error_code, $status->{error});
                    }

                    return Future->done({
                        status                => 1,
                        binary_transaction_id => $txn->id
                    });
                });
        });
};

async_rpc mt5_withdrawal => sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_mt5, $to_loginid, $amount) =
        @{$args}{qw/from_mt5 to_binary amount/};

    my $error_code = 'MT5WithdrawalError';
    return _mt5_validate_and_get_amount($client, $to_loginid, $fm_mt5, $amount, $error_code)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});

            my $mt5_amount = $response;

            my $to_client_db = BOM::Database::ClientDB->new({
                client_loginid => $to_loginid,
            });

            return _make_error($error_code, localize('Please try again after one minute.'), "Account stuck in previous transaction $to_loginid")
                if (not $to_client_db->freeze);

            scope_guard {
                $to_client_db->unfreeze;
            };

            my $comment = "Transfer from MT5 account $fm_mt5 to $to_loginid.";
            # withdraw from MT5 a/c
            return BOM::MT5::User::Async::withdrawal({
                    login   => $fm_mt5,
                    amount  => $amount,
                    comment => $comment
                }
                )->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        return _make_error($error_code, $status->{error});
                    }

                    my $to_client = BOM::User::Client->new({loginid => $to_loginid});

                    # TODO(leonerd): This Try::Tiny try block returns a Future in either case.
                    #   We might want to consider using Future->try somehow instead.
                    return try {
                        # deposit to Binary a/c
                        my $account = $to_client->default_account;
                        my ($payment) = $account->add_payment({
                            amount               => $mt5_amount,
                            payment_gateway_code => 'account_transfer',
                            payment_type_code    => 'internal_transfer',
                            status               => 'OK',
                            staff_loginid        => $to_loginid,
                            remark               => $comment,
                        });
                        my ($txn) = $payment->add_transaction({
                            account_id    => $account->id,
                            amount        => $mt5_amount,
                            staff_loginid => $to_loginid,
                            referrer_type => 'payment',
                            action_type   => 'deposit',
                            quantity      => 1,
                            source        => $source,
                        });
                        $account->save(cascade => 1);
                        $payment->save(cascade => 1);

                        return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn->id
                        });
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
                        return _make_error($error_code, $error->{-message_to_client});
                    };
                });
        });
};

rpc mt5_mamm => sub {
    my $params = shift;

    my $mt5_suspended = _is_mt5_suspended();
    return $mt5_suspended if $mt5_suspended;

    my ($client, $args)   = @{$params}{qw/client args/};
    my ($login,  $action) = @{$args}{qw/login action/};

    # MT5 login not belongs to client
    return BOM::RPC::v3::Utility::permission_error()
        unless _check_logins($client, ['MT' . $login]);

    my $settings = BOM::MT5::User::get_user($login);
    return _mt5_error_sub() if (ref $settings eq 'HASH' and $settings->{error});

    # to revoke manager we just disable trading for mt5 account
    # we cannot change group else accounting team will have problem during
    # reconciliation.
    # we cannot remove agent fields as thats used for auditing else
    # it would have been a simple check
    #
    # MT5 way to disable trading is not very intuitive, its based on
    # https://support.metaquotes.net/en/docs/mt5/api/reference_user/imtuser/imtuser_enum#enusersrights
    # and rights column from user setting return numbers based on combination
    # of these enumerations,
    #
    # 483  - All options except OTP and change password (default)
    # 1507 - All options except OTP
    # 2531 - All options except change password
    # 3555 - All options enabled
    #
    # 4 is score for disabled trading
    my $current_rights = $settings->{rights};
    my $has_manager = (grep { $_ == $current_rights } qw/483 1503 2527 3555/) ? 1 : 0;

    if ($action) {
        if ($action eq 'revoke' and $has_manager) {
            my $response = _mt5_has_open_positions($login);
            return _mt5_error_sub() if (ref $response eq 'HASH' and $response->{error});

            return _mt5_error_sub('PermissionDenied',
                localize('Please close out all open positions before revoking manager associated with your account.'))
                if $response;

            $settings->{rights} += 4;
            BOM::MT5::User::update_mamm_user($settings);
            return _mt5_error_sub() if (ref $settings eq 'HASH' and $settings->{error});

            return {
                status     => 1,
                manager_id => ''
            };
        }
    } else {
        return $has_manager
            ? {
            status     => 1,
            manager_id => $settings->{agent} || ''
            }
            : {
            status     => 1,
            manager_id => ''
            };
    }

    return {
        status     => 0,
        manager_id => ''
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
        $affiliate_variables = [$affiliate_variables]
            unless ref($affiliate_variables) eq 'ARRAY';

        my ($mt5_account) =
            grep { $_->{NAME} eq 'mt5_account' } @$affiliate_variables;
        return $mt5_account->{VALUE} if $mt5_account;
    }

    return;
}

sub _mt5_validate_and_get_amount {
    my ($authorized_client, $loginid, $mt5_loginid, $amount, $error_code) = @_;

    my $mt5_suspended = _is_mt5_suspended();
    return Future->done($mt5_suspended) if $mt5_suspended;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    return _make_error($error_code, localize('Payments are suspended.'))
        if ($app_config->system->suspend->payments or $app_config->system->suspend->system);

    return _make_error($error_code, localize("Amount must be greater than zero.")) if ($amount <= 0);

    # MT5 login or binary loginid not belongs to user
    return permission_error_future() unless _check_logins($authorized_client, ['MT' . $mt5_loginid, $loginid]);

    my $client_obj;
    try {
        $client_obj = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        });
    } or return _make_error($error_code, localize('Invalid loginid - [_1].', $loginid));

    # only for real money account
    return permission_error_future() if ($client_obj->is_virtual);

    return _make_error($error_code, localize('Your account [_1] is disabled.', $loginid))
        if ($client_obj->get_status('disabled'));

    return _make_error($error_code, localize('Your account [_1] cashier section is locked.', $loginid))
        if ($client_obj->get_status('cashier_locked') || $client_obj->documents_expired);

    my $client_currency = $client_obj->default_account ? $client_obj->default_account->currency_code : undef;
    return _make_error($error_code, localize('Please set currency for existsing account [_1].', $loginid))
        unless $client_currency;

    return _make_error(
        $error_code,
        localize(
            'Invalid amount. Amount provided can not have more than [_1] decimal places.',
            Format::Util::Numbers::get_precision_config()->{amount}->{$client_currency})
    ) if ($amount != financialrounding('amount', $client_currency, $amount));

    return mt5_get_settings({
            client => $authorized_client,
            args   => {login => $mt5_loginid}}
        )->then(
        sub {
            my ($setting) = @_;

            return _make_error($error_code, localize('Unable to get account details for your MT5 account [_1].', $mt5_loginid))
                if (ref $setting eq 'HASH' && $setting->{error});

            # check if mt5 account is real
            return permission_error_future() unless ($setting->{group} // '') =~ /^real\\/;

            my $action = ($error_code =~ /Withdrawal/) ? 'withdrawal' : 'deposit';

            return _make_error($error_code,
                localize('Permission error. MAMM manager accounts are not allowed to withdraw as payments are processed manually.'))
                if ($action eq 'withdrawal' and ($setting->{group} // '') =~ /^real\\mamm_/);

            # check for fully authenticated only if it's not gaming account
            # as of now we only support gaming for binary brand, in future if we
            # support for champion please revisit this
            return _make_error($error_code, localize('Please authenticate your account.'))
                if ($action eq 'withdrawal'
                and ($setting->{group} // '') !~ /^real\\costarica$/
                and not $authorized_client->client_fully_authenticated);

            my $mt5_currency = $setting->{currency};
            return _make_error($error_code, localize('Invalid MT5 currency - had [_1] and should be USD or EUR.', $mt5_currency))
                unless $mt5_currency =~ /^USD|EUR$/;

            my $mt5_amount = undef;
            if ($client_currency eq $mt5_currency) {
                $mt5_amount = $amount;
                # Actual USD or EUR amount that will be deposited into the MT5 account. We have
                # a fixed 1% fee on all conversions, but this is only ever applied when converting
                # between currencies - we do not apply for USD -> USD transfers for example.
            } elsif ($action eq 'deposit') {
                $mt5_amount = try {
                    financialrounding('amount', $client_currency,
                        amount_from_to_currency($amount, $client_currency, $mt5_currency, CURRENCY_CONVERSION_MAX_AGE) * 0.99)
                }
                catch {
                    warn "Conversion failed for mt5_$action: $_";
                    return undef;
                };
            } elsif ($action eq 'withdrawal') {
                $mt5_amount = try {
                    financialrounding('amount', $client_currency,
                        amount_from_to_currency($amount, $mt5_currency, $client_currency, CURRENCY_CONVERSION_MAX_AGE) * 0.99);
                }
                catch {
                    warn "Conversion failed for mt5_$action: $_";
                    return undef;
                };
            }

            return _make_error($error_code, localize("Conversion rate not available for this currency."))
                unless defined $mt5_amount;

            return _make_error($error_code, localize("Amount must be greater than 1 [_1].", $mt5_currency))
                if $mt5_amount < 1;
            return _make_error($error_code, localize("Amount must be less than 20000 [_1].", $mt5_currency))
                if $mt5_amount > 20000;

            return Future->done($mt5_amount);
        });
}

sub _mt5_has_open_positions {
    my $login = shift;

    my $response = BOM::MT5::User::get_open_positions_count({login => $login});
    return _mt5_error_sub() if $response->{error};

    return $response->{total} ? 1 : 0;
}
1;

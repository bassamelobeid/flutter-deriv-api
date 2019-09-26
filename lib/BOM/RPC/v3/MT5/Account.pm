package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

no indirect;

use Guard;
use YAML::XS;
use Date::Utility;
use List::Util qw(any first);
use Try::Tiny;
use File::ShareDir;
use Locale::Country::Extra;
use WebService::MyAffiliates;
use Future::Utils qw(fmap1);
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::MaybeXS;
use DataDog::DogStatsd::Helper qw(stats_inc);
use Digest::SHA qw(sha384_hex);

use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw/convert_currency/;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::MT5::Errors;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User;
use BOM::User::Client;
use BOM::MT5::User::Async;
use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use BOM::Platform::Email;
use BOM::Transaction;
use BOM::User::FinancialAssessment qw(is_section_complete decode_fa);

requires_auth();

use constant MT5_ACCOUNT_THROTTLE_KEY_PREFIX => 'MT5ACCOUNT::THROTTLE::';

use constant MT5_MALTAINVEST_MOCK_LEVERAGE => 33;
use constant MT5_MALTAINVEST_REAL_LEVERAGE => 30;

use constant MT5_SVG_STANDARD_MOCK_LEVERAGE => 1;
use constant MT5_SVG_STANDARD_REAL_LEVERAGE => 1000;

# Defines mt5 account rights combination when trading is enabled
use constant MT5_ACCOUNT_TRADING_ENABLED_RIGHTS_ENUM => qw(
    483 1503 2527 3555
);

my $error_registry = BOM::RPC::v3::MT5::Errors->new();

sub create_error_future {
    my ($error_code, $details, @extra) = @_;
    if (ref $details eq 'HASH' and ref $details->{message} eq 'HASH') {
        return Future->done({error => $details->{message}});
    }
    return Future->done($error_registry->format_error($error_code, $details, @extra));

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

=back

=cut

async_rpc "mt5_login_list",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    return get_mt5_logins($client)->then(
        sub {
            my (@logins) = @_;
            return Future->done(\@logins);
        });
    };

sub get_mt5_logins {
    my ($client, $user) = @_;

    $user ||= $client->user;

    my $f = fmap1 {
        shift =~ /^MT(\d+)$/;
        my $login = $1;
        return mt5_get_settings({
                client => $client,
                args   => {login => $login}}
            )->then(
            sub {
                my ($setting) = @_;
                $setting = _filter_settings($setting, qw/balance display_balance country currency email group leverage login name/);
                return Future->needs_all(
                    mt5_mamm({
                            client => $client,
                            args   => {login => $login}}
                    ),
                    Future->done($setting));
            }
            )->then(
            sub {
                my ($mamm, $setting) = @_;
                @{$setting}{keys %$mamm} = values %$mamm;
                $setting->{mamm_status} = delete $setting->{status};
                return Future->done($setting);
            });
    }
    foreach        => [$user->mt5_logins],
        concurrent => 4;
# purely to keep perlcritic+perltidy happy :(
    return $f;
}

# limit number of requests to once per minute
sub _throttle {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return 1 if BOM::Config::RedisReplicated::redis_read()->get($key);

    BOM::Config::RedisReplicated::redis_write()->set($key, 1, 'EX', 60);

    return 0;
}

# removes the database entry that limit requests to 1/minute
# returns 1 if entry was present, 0 otherwise
sub reset_throttler {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return BOM::Config::RedisReplicated::redis_write()->del($key);
}

sub _mt5_group {
    # account_type:     demo|gaming|financial
    # sub_account_type: standard|advanced
    my ($company_name, $account_type, $sub_account_type, $manager_id, $currency) = @_;

    # for Maltainvest if the client uses GBP as currency we should add this to the group name
    my $GBP = ($currency eq 'GBP' and $company_name eq 'maltainvest') ? '_GBP' : '';

    # for demo accounts we recognize company type if sub_account_type is available or not
    if ($account_type eq 'demo') {
        return "demo\\${company_name}_$sub_account_type${GBP}" if length $sub_account_type;
        return "demo\\$company_name";
    } else {
        $sub_account_type = "_${sub_account_type}" if $account_type eq 'financial';

        return "real\\${company_name}${sub_account_type}${GBP}" unless $manager_id;
        return "real\\${company_name}_mamm${sub_account_type}${GBP}_${manager_id}";
    }
}

async_rpc "mt5_new_account",
    category => 'mt5',
    sub {
    my $params = shift;
    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my $error_code = 'MT5CreateUserError';

    my ($client, $args) = @{$params}{qw/client args/};

    # extract request parameters
    my $account_type     = delete $args->{account_type};
    my $mt5_account_type = delete $args->{mt5_account_type} // '';
    my $manager_id       = delete $args->{manager_id};

    # input validation
    return create_error_future('SetExistingAccountCurrency') unless $client->default_account;

    my $invalid_account_type_error = create_error_future('InvalidAccountType');
    return $invalid_account_type_error if (not $account_type or $account_type !~ /^demo|gaming|financial$/);

    $mt5_account_type = '' if $account_type eq 'gaming';
    $args->{investPassword} = _generate_password($args->{mainPassword}) unless $args->{investPassword};

    return create_error_future('MT5SamePassword') if (($args->{mainPassword} // '') eq ($args->{investPassword} // ''));

    return create_error_future('InvalidSubAccountType')
        if ($mt5_account_type and $mt5_account_type !~ /^standard|advanced$/)
        or ($account_type eq 'financial' and $mt5_account_type eq '');

    # legal validation
    my $residence = $client->residence;

    my $brand              = request()->brand;
    my $countries_instance = $brand->countries_instance;
    my $countries_list     = $countries_instance->countries_list;

    return create_error_future('permission') unless $countries_list->{$residence};

    # demo account is not allowed for mamm account
    return $invalid_account_type_error if $manager_id and $account_type eq 'demo';

    my $user = $client->user;

    # demo accounts type determined if this parameter exists or not
    my $company_type = $mt5_account_type eq '' ? 'gaming' : 'financial';
    my $company_name = $countries_instance->mt_company_for_country(
        country          => $residence,
        account_type     => $company_type,
        sub_account_type => $mt5_account_type
    );

    # MT5 is not allowed in client country
    return create_error_future('MT5NotAllowed', {params => $company_type}) if $company_name eq 'none';

    my $binary_company_name = $countries_list->{$residence}->{"${company_type}_company"};

    my $source_client = $client;

    # Binary.com front-end will pass whichever client is currently selected
    # in the top-right corner, so check if this user has a qualifying account and switch if they do.
    if ($account_type ne 'demo' and $client->landing_company->short ne $binary_company_name) {
        my @clients = $user->clients_for_landing_company($binary_company_name);
        $client = (@clients > 0) ? $clients[0] : undef;
    }

    unless ($client) {
        if (scalar($user->clients) == 1 and $source_client->is_virtual() and $account_type ne 'demo') {
            return create_error_future('RealAccountMissing');
        } elsif ($account_type eq 'financial') {
            return create_error_future('FinancialAccountMissing');
        } elsif ($account_type eq 'gaming') {
            return create_error_future('GamingAccountMissing');
        }

        return create_error_future('permission');
    }

    return create_error_future('permission') if ($client->is_virtual() and $account_type ne 'demo');

    my $requirements        = LandingCompany::Registry->new->get($company_name)->requirements;
    my $signup_requirements = $requirements->{signup};
    my @missing_fields      = grep { !$client->$_ } @$signup_requirements;

    return create_error_future(
        'MissingSignupDetails',
        {
            override_code => 'ASK_FIX_DETAILS',
            details       => {missing => [@missing_fields]}}) if ($account_type ne "demo" and @missing_fields);

    my $group = _mt5_group($company_name, $account_type, $mt5_account_type, $manager_id, $client->currency);
    return create_error_future('permission') if $group eq '';

    if ($client->residence eq 'gb' and not $client->status->age_verification) {
        return ($client->is_virtual() and $user->clients == 1)
            ? create_error_future('RealAccountMissing')
            : create_error_future('NoAgeVerification');
    }

    my $compliance_requirements = $requirements->{compliance};
    return create_error_future('FinancialAssessmentMandatory')
        unless _is_financial_assessment_complete(
        client                            => $client,
        group                             => $group,
        financial_assessment_requirements => $compliance_requirements->{financial_assessment});

    # Following this regulation: Labuan Business Activity Tax
    # (Automatic Exchange of Financial Account Information) Regulation 2018,
    # we need to ask for tax details for selected countries if client wants
    # to open a financial account.
    return create_error_future('TINDetailsMandatory')
        if ($compliance_requirements->{tax_information}
        and $countries_instance->is_tax_detail_mandatory($residence)
        and not $client->status->crs_tin_information);

    # Check if client is throttled before sending MT5 request
    if (_throttle($client->loginid)) {
        return create_error_future('Throttle', {override_code => $error_code});
    }

    return get_mt5_logins($client, $user)->then(
        sub {
            my (@logins) = @_;

            foreach (@logins) {
                if (($_->{group} // '') eq $group) {
                    my $login = $_->{login};

                    return create_error_future(
                        'MT5Duplicate',
                        {
                            override_code => $error_code,
                            params        => [$account_type, $login]});
                }
            }

            # TODO(leonerd): This has to nest because of the `Future->done` in the
            #   foreach loop above. A better use of errors-as-failures might avoid
            #   this.
            return BOM::MT5::User::Async::get_group($group)->then(
                sub {
                    my ($group_details) = @_;
                    if (ref $group_details eq 'HASH' and my $error = $group_details->{error}) {
                        if ($error =~ /Not enough permissions/ && defined $manager_id) {
                            return create_error_future($error_code);
                        } else {
                            return create_error_future($error_code, {message => $error});
                        }
                    }
                    # some MT5 groups should have leverage as 30
                    # but MT5 only support 33
                    if ($group_details->{leverage} == MT5_MALTAINVEST_MOCK_LEVERAGE) {
                        $group_details->{leverage} = MT5_MALTAINVEST_REAL_LEVERAGE;
                    } elsif ($group_details->{leverage} == MT5_SVG_STANDARD_MOCK_LEVERAGE) {
                        # MT5 bug it should be solved by MetaQuote
                        $group_details->{leverage} = MT5_SVG_STANDARD_REAL_LEVERAGE;
                    }

                    my $client_info = $client->get_mt5_details();
                    $client_info->{name} = $args->{name} if $client->is_virtual;
                    @{$args}{keys %$client_info} = values %$client_info;
                    $args->{group}    = $group;
                    $args->{leverage} = $group_details->{leverage};
                    $args->{currency} = $group_details->{currency};

                    # populate mt5 agent account from manager id if applicable
                    # else get one associated with affiliate token
                    if ($manager_id) {
                        $args->{agent} = $manager_id;
                    } elsif ($client->myaffiliates_token and $account_type ne 'demo') {
                        my $agent_login = _get_mt5_account_from_affiliate_token($client->myaffiliates_token);
                        $args->{agent} = $agent_login if $agent_login;
                        warn "Failed to link " . $client->loginid . " MT5 account with myaffiliates token " . $client->myaffiliates_token
                            unless $agent_login;
                    }

                    return BOM::MT5::User::Async::create_user($args);
                }
                )->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        return create_error_future('permission') if $status->{error} =~ /Not enough permissions/;
                        return create_error_future($error_code, {message => $status->{error}});
                    }
                    my $mt5_login = $status->{login};

                    # eg: MT5 login: 1000, we store MT1000
                    $user->add_loginid('MT' . $mt5_login);

                    BOM::Platform::Event::Emitter::emit(
                        'new_mt5_signup',
                        {
                            loginid      => $client->loginid,
                            account_type => $account_type,
                            mt5_group    => $group,
                            mt5_login_id => $mt5_login,
                            cs_email     => $brand->emails('support'),
                            language     => $params->{language}});

                    # Compliance team must be notified if a client under Binary (Europe) Limited
                    #   opens an MT5 account while having limitations on their account.
                    if ($client->landing_company->short eq 'malta' && $account_type ne 'demo') {
                        my $self_exclusion = BOM::RPC::v3::Accounts::get_self_exclusion({client => $client});
                        if (keys %$self_exclusion) {
                            warn 'Compliance email regarding Binary (Europe) Limited user with MT5 account(s) failed to send.'
                                unless BOM::RPC::v3::Accounts::send_self_exclusion_notification($client, 'malta_with_mt5', $self_exclusion);
                        }
                    }

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
                                do_mt5_deposit($mt5_login, $balance, 'Binary MT5 Virtual Money deposit.')->on_done(
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
                            # Get currency from MT5 group
                            return BOM::MT5::User::Async::get_group($group);
                        }
                        )->then(
                        sub {
                            my ($group_details) = @_;
                            return create_error_future('MT5CreateUserError', {message => $group_details->{error}})
                                if ref $group_details eq 'HASH' and $group_details->{error};

                            return Future->done({
                                    login           => $mt5_login,
                                    balance         => $balance,
                                    display_balance => formatnumber('amount', $args->{currency}, $balance),
                                    currency        => $args->{currency},
                                    account_type    => $account_type,
                                    agent           => $args->{agent},
                                    ($mt5_account_type) ? (mt5_account_type => $mt5_account_type) : ()});
                        });
                });
        });
    };

=head2 _is_financial_assessment_complete

Checks the financial assessment requirements of creating an account in an MT5 group.

Takes named argument with the following as key parameters:

=over 4

=item * $client: an instance of C<BOM::User::Client> representing a binary client onject.

=item * $group: the target MT5 group.

=item * $financial_assessment_requirements for particular landing company.

=back

Returns 1 of the financial assemssments meet the requirements; otherwise returns 0.

=cut

sub _is_financial_assessment_complete {
    my %args = @_;

    my $client = $args{client};
    my $group  = $args{group};

    return 1 if $group =~ /^demo/;

    # this case doesn't follow the general rule (labuan are exclusively mt5 landing companies).
    if (my $financial_assessment_requirements = $args{financial_assessment_requirements}) {
        my $financial_assessment = decode_fa($client->financial_assessment());

        my $is_FI =
            (first { $_ eq 'financial_information' } @{$args{financial_assessment_requirements}})
            ? is_section_complete($financial_assessment, 'financial_information')
            : 1;
        my $is_TE =
            (first { $_ eq 'trading_experience' } @{$args{financial_assessment_requirements}})
            ? is_section_complete($financial_assessment, 'trading_experience')
            : 1;

        ($is_FI and $is_TE) ? return 1 : return 0;
    }

    return $client->is_financial_assessment_complete();
}

sub _check_logins {
    my ($client, $logins) = @_;
    my $user = $client->user;

    foreach my $login (@{$logins}) {
        return unless (any { $login eq $_ } ($user->loginids));
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

async_rpc "mt5_get_settings",
    category => 'mt5',
    sub {
    my $params = shift;

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::get_user($login)->then(
        sub {
            my ($settings) = @_;
            return create_error_future('MT5GetUserError', {message => $settings->{error}}) if (ref $settings eq 'HASH' and $settings->{error});
            if (my $country = $settings->{country}) {
                my $country_code = Locale::Country::Extra->new()->code_from_country($country);
                if ($country_code) {
                    $settings->{country} = $country_code;
                } else {
                    warn "Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra";
                }
            }
            return Future->done($settings);
        }
        )->then(
        sub {
            my ($settings) = @_;
            return BOM::MT5::User::Async::get_group($settings->{group})->then(
                sub {
                    my ($group_details) = @_;
                    return create_error_future('MT5GetGroupError', {message => $group_details->{error}})
                        if (ref $group_details eq 'HASH' and $group_details->{error});
                    $settings->{currency}        = $group_details->{currency};
                    $settings->{landing_company} = $group_details->{company};
                    $settings->{display_balance} = formatnumber('amount', $settings->{currency}, $settings->{balance});
                    $settings                    = _filter_settings($settings,
                        qw/address balance city company country currency email group leverage login name phone phonePassword state zipCode landing_company display_balance/
                    );
                    return Future->done($settings);
                });
        });
    };

sub _filter_settings {
    my ($settings, @allowed_keys) = @_;
    my $filtered_settings = {};
    @{$filtered_settings}{@allowed_keys} = @{$settings}{@allowed_keys};
    return $filtered_settings;
}

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

async_rpc "mt5_password_check",
    category => 'mt5',
    sub {
    my $params = shift;

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::password_check({
            login    => $args->{login},
            password => $args->{password},
            type     => $args->{password_type} // 'main'
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future('MT5PasswordCheckError', {message => $status->{error}});
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

async_rpc "mt5_password_change",
    category => 'mt5',
    sub {
    my $params = shift;

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    return create_error_future('MT5PasswordChangeError') if $args->{old_password} and ($args->{new_password} eq $args->{old_password});
    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, ['MT' . $login]);

    if (_throttle($client->loginid)) {
        return create_error_future('Throttle', {override_code => 'MT5PasswordChangeError'});
    }

    return BOM::MT5::User::Async::password_check({
            login    => $login,
            password => $args->{old_password},
            type     => $args->{password_type} // 'main',
        }
        )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future($status->{code}, {override_code => 'MT5PasswordChangeError'});
            }

            return BOM::MT5::User::Async::password_change({
                    login        => $login,
                    new_password => $args->{new_password},
                    type         => $args->{password_type} // 'main',
                })->then_done(1);
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

async_rpc "mt5_password_reset",
    category => 'mt5',
    sub {
    my $params = shift;

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    my $email = BOM::Platform::Token->new({token => $args->{verification_code}})->email;

    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'mt5_password_reset')->{error}) {
        return create_error_future($err);
    }

    # MT5 login not belongs to user
    return create_error_future('permission')
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
                return create_error_future($status->{code}, {override_code => 'MT5PasswordChangeError'});
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

async_rpc "mt5_deposit",
    category => 'mt5',
    sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_loginid, $to_mt5, $amount, $return_mt5_details) =
        @{$args}{qw/from_binary to_mt5 amount return_mt5_details/};

    my $error_code = 'MT5DepositError';
    my $app_config = BOM::Config::Runtime->instance->app_config;

    # no need to throttle this call only limited numbers of transfers are allowed

    if (_is_mt5_suspended('deposits')) {
        return create_error_future('MT5DepositSuspended', {override_code => $error_code});
    }

    return _mt5_validate_and_get_amount($client, $fm_loginid, $to_mt5, $amount, $error_code)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});

            if ($response->{top_up_virtual}) {

                my $amount_to_topup = 10000;

                return do_mt5_deposit($to_mt5, $amount_to_topup, 'Binary MT5 Virtual Money deposit.')->then(
                    sub {
                        my ($status) = @_;

                        if ($status->{error}) {
                            return create_error_future($status->{code});
                        }

                        reset_throttler($to_mt5);

                        return Future->done({status => 1});
                    });
            }

            # withdraw from Binary a/c
            my $fm_client_db = BOM::Database::ClientDB->new({
                client_loginid => $fm_loginid,
            });
            return create_error_future(
                'ClientFrozen',
                {
                    override_code => $error_code,
                    params        => $fm_loginid
                }) if (not $fm_client_db->freeze);

            scope_guard {
                $fm_client_db->unfreeze;
            };

            my $fm_client = BOM::User::Client->new({loginid => $fm_loginid});

            # From the point of view of our system, we're withdrawing
            # money to deposit into MT5
            my $withdraw_error;
            try {
                $fm_client->validate_payment(
                    currency => $fm_client->default_account->currency_code(),
                    amount   => -$amount,
                );
            }
            catch {
                $withdraw_error = $_;
            };

            if ($withdraw_error) {
                return create_error_future(
                    $error_code,
                    {
                        message => BOM::RPC::v3::Cashier::__client_withdrawal_notes({
                                client => $fm_client,
                                amount => $amount,
                                error  => $withdraw_error
                            })});
            }

            my $fees              = $response->{fees};
            my $fees_currency     = $response->{fees_currency};
            my $fees_percent      = $response->{fees_percent};
            my $mt5_currency_code = $response->{mt5_currency_code};
            my ($txn, $comment, $error);
            try {
                my $fee_calculated_by_percent = $response->{calculated_fee};
                my $min_fee                   = $response->{min_fee};

                $comment = "Transfer from $fm_loginid to MT5 account $to_mt5.";
                my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(
                    fees                      => $fees,
                    fee_percent               => $fees_percent,
                    currency                  => $fees_currency,
                    minimum_fee               => $min_fee,
                    fee_calculated_by_percent => $fee_calculated_by_percent
                );
                $comment = "$comment $additional_comment" if $additional_comment;

                ($txn) = $fm_client->payment_mt5_transfer(
                    amount   => -$amount,
                    currency => $fm_client->currency,
                    staff    => $fm_loginid,
                    remark   => $comment,
                    fees     => $fees,
                    source   => $source,
                );

                _record_mt5_transfer($fm_client->db->dbic, $txn->payment_id, -$response->{mt5_amount}, $to_mt5, $response->{mt5_currency_code});
            }
            catch {
                $error = BOM::Transaction->format_error(err => $_);
            };

            return create_error_future($error_code, {message => $error->{-message_to_client}}) if $error;

            _store_transaction_redis({
                    loginid       => $fm_loginid,
                    mt5_id        => $to_mt5,
                    action        => 'deposit',
                    amount_in_USD => convert_currency($amount, $fm_client->currency, 'USD'),
                }) if ($response->{mt5_data}->{group} eq 'real\vanuatu_standard');

            my $txn_id = $txn->transaction_id;
            # 31 character limit for MT5 comments
            my $mt5_comment = "${fm_loginid}_${to_mt5}#$txn_id";

            # deposit to MT5 a/c
            return do_mt5_deposit($to_mt5, $response->{mt5_amount}, $mt5_comment, $txn_id)->then(
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
                        return create_error_future($status->{code});
                    }

                    return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn_id,
                            $return_mt5_details ? (mt5_data => $response->{mt5_data}) : ()});
                });
        });
    };

async_rpc "mt5_withdrawal",
    category => 'mt5',
    sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_mt5, $to_loginid, $amount, $currency_check) =
        @{$args}{qw/from_mt5 to_binary amount currency_check/};

    my $error_code = 'MT5WithdrawalError';
    my $app_config = BOM::Config::Runtime->instance->app_config;

    # no need to throttle this call only limited numbers of transfers are allowed

    if (_is_mt5_suspended('withdrawals')) {
        return create_error_future('MT5WithdrawalSuspended', {override_code => $error_code});
    }

    return create_error_future('WithdrawalLocked', {override_code => $error_code}) if $client->status->mt5_withdrawal_locked;

    return _mt5_validate_and_get_amount($client, $to_loginid, $fm_mt5, $amount, $error_code, $currency_check)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});

            my $to_client_db = BOM::Database::ClientDB->new({
                client_loginid => $to_loginid,
            });

            return create_error_future(
                'ClientFrozen',
                {
                    override_code => $error_code,
                    params        => $to_loginid
                }) if (not $to_client_db->freeze);

            scope_guard {
                $to_client_db->unfreeze;
            };

            my $fees                      = $response->{fees};
            my $fees_currency             = $response->{fees_currency};
            my $fees_in_client_currency   = $response->{fees_in_client_currency};
            my $mt5_amount                = $response->{mt5_amount};
            my $fees_percent              = $response->{fees_percent};
            my $mt5_currency_code         = $response->{mt5_currency_code};
            my $fee_calculated_by_percent = $response->{calculated_fee};
            my $min_fee                   = $response->{min_fee};

            my $comment            = "Transfer from MT5 account $fm_mt5 to $to_loginid.";
            my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(
                fees                      => $fees,
                fee_percent               => $fees_percent,
                currency                  => $fees_currency,
                minimum_fee               => $min_fee,
                fee_calculated_by_percent => $fee_calculated_by_percent
            );

            $comment = "$comment $additional_comment" if $additional_comment;

            # 31 character limit for MT5 comments
            my $mt5_comment = "${fm_mt5}_${to_loginid}";

            my $mt5_group = $response->{mt5_data}->{group};
            #MT5 expect this value to be negative.
            # withdraw from MT5 a/c
            return do_mt5_withdrawal($fm_mt5, (($amount > 0) ? $amount * -1 : $amount), $mt5_comment)->then(
                sub {
                    my ($status) = @_;
                    return create_error_future($status->{code}) if (ref $status eq 'HASH' and $status->{error});

                    my $to_client = BOM::User::Client->new({loginid => $to_loginid});

                    # TODO(leonerd): This Try::Tiny try block returns a Future in either case.
                    #   We might want to consider using Future->try somehow instead.
                    return try {
                        # deposit to Binary a/c
                        my ($txn) = $to_client->payment_mt5_transfer(
                            amount   => $mt5_amount,
                            currency => $to_client->currency,
                            staff    => $to_loginid,
                            remark   => $comment,
                            fees     => $fees_in_client_currency,
                            source   => $source,
                        );

                        _record_mt5_transfer($to_client->db->dbic, $txn->payment_id, $amount, $fm_mt5, $mt5_currency_code);

                        _store_transaction_redis({
                                loginid       => $to_loginid,
                                mt5_id        => $fm_mt5,
                                action        => 'withdraw',
                                amount_in_USD => $amount,
                            }) if ($mt5_group eq 'real\vanuatu_standard');

                        return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn->transaction_id
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
                        return create_error_future($error_code, {message => $error->{-message_to_client}});
                    };
                });
        });
    };

async_rpc "mt5_mamm",
    category => 'mt5',
    sub {
    my $params = shift;

    return create_error_future('MT5APISuspendedError') if _is_mt5_suspended();

    my ($client, $args)   = @{$params}{qw/client args/};
    my ($login,  $action) = @{$args}{qw/login action/};
    my $error_code = 'PermissionDenied';
    # MT5 login not belongs to client
    return create_error_future('permission')
        unless _check_logins($client, ['MT' . $login]);

    return BOM::MT5::User::Async::get_user($login)->then(
        sub {
            my ($settings) = @_;

            return create_error_future($error_code, {message => $settings->{error}}) if (ref $settings eq 'HASH' and $settings->{error});
            return create_error_future('HaveOpenPositions', {override_code => $error_code})
                if ($action and $action eq 'revoke' and ($settings->{balance} // 0) > 0);

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
            my $current_rights = $settings->{rights} // 0;
            my $has_manager = ($settings->{group} =~ /mamm/ and any { $_ == $current_rights } MT5_ACCOUNT_TRADING_ENABLED_RIGHTS_ENUM) ? 1 : 0;

            return Future->done({
                    status     => 0,
                    manager_id => ''
                }) unless $has_manager;

            # if agent is not set then mt5 returns 0 hence || not //
            return Future->done({
                    status     => 1,
                    manager_id => $settings->{agent} || ''
                }) if (not $action or $action ne 'revoke');

            return _mt5_has_open_positions($login)->then(
                sub {
                    my ($open_positions) = @_;
                    return create_error_future($error_code, {message => $open_positions->{error}})
                        if (ref $open_positions eq 'HASH' and $open_positions->{error});

                    return create_error_future('HaveOpenPositions', {override_code => $error_code}) if $open_positions;

                    $settings->{rights} += 4;
                    return BOM::MT5::User::Async::update_mamm_user($settings)->then(
                        sub {
                            my ($user_updated) = @_;
                            return create_error_future($error_code, {message => $open_positions->{error}})
                                if (ref $user_updated eq 'HASH' and $user_updated->{error});

                            return Future->done({
                                status     => 1,
                                manager_id => ''
                            });
                        });
                });
        }
        )->else(
        sub {
            my ($code, $error) = @_;
            return create_error_future($code, {message => $error});
        });
    };

sub _is_mt5_suspended {
    my ($feature_name) = @_;
    my $app_config = BOM::Config::Runtime->instance->app_config->system->mt5->suspend;

    # always check if all calls are suspended.
    if (($feature_name and $app_config->$feature_name) or $app_config->all) {
        return 1;
    } else {
        return 0;
    }
}

sub _get_mt5_account_from_affiliate_token {
    my $token = shift;

    if ($token) {
        my $aff = WebService::MyAffiliates->new(
            user    => BOM::Config::third_party()->{myaffiliates}->{user},
            pass    => BOM::Config::third_party()->{myaffiliates}->{pass},
            host    => BOM::Config::third_party()->{myaffiliates}->{host},
            timeout => 10
            )
            or do {
            stats_inc('myaffiliates.mt5.failure.connect', 1);
            return 0;
            };

        my $user_id = $aff->get_affiliate_id_from_token($token) or do {
            stats_inc('myaffiliates.mt5.failure.get_aff_id', 1);
            return 0;
        };

        my $user = $aff->get_user($user_id) or do {
            stats_inc('myaffiliates.mt5.failure.get_user', 1);
            return 0;
        };

        my $affiliate_variables = $user->{USER_VARIABLES}->{VARIABLE} or do {
            stats_inc('myaffiliates.mt5.failure.no_info', 1);
            return 0;
        };
        $affiliate_variables = [$affiliate_variables]
            unless ref($affiliate_variables) eq 'ARRAY';

        my ($mt5_account) =
            grep { $_->{NAME} eq 'mt5_account' } @$affiliate_variables;
        return $mt5_account->{VALUE} if $mt5_account;
    }

    return;
}

sub _mt5_validate_and_get_amount {
    my ($authorized_client, $loginid, $mt5_loginid, $amount, $error_code, $currency_check) = @_;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return create_error_future('PaymentsSuspended', {override_code => $error_code})
        if ($app_config->system->suspend->payments);

    # MT5 login or binary loginid not belongs to user
    my @loginids_list = ('MT' . $mt5_loginid);
    push @loginids_list, $loginid if $loginid;

    return create_error_future('permission') unless _check_logins($authorized_client, \@loginids_list);

    return mt5_get_settings({
            client => $authorized_client,
            args   => {login => $mt5_loginid}}
        )->then(
        sub {

            my ($setting) = @_;

            return create_error_future(
                'NoAccountDetails',
                {
                    override_code => $error_code,
                    params        => $mt5_loginid
                }) if (ref $setting eq 'HASH' && $setting->{error});

            my $action = ($error_code =~ /Withdrawal/) ? 'withdrawal' : 'deposit';

            my $mt5_group    = $setting->{group};
            my $mt5_lc       = _fetch_mt5_lc($setting);
            my $mt5_currency = $setting->{currency};

            return create_error_future('CurrencyConflict', {override_code => $error_code})
                if $currency_check && $currency_check ne $mt5_currency;

            # Check if id is a demo account
            # If yes, then no need to validate client
            if (_is_account_demo($mt5_group)) {
                return create_error_future('NoDemoWithdrawals', {override_code => $error_code})
                    if $action eq 'withdrawal';

                return create_error_future('TransferBetweenAccountsError', {override_code => $error_code})
                    if $action eq 'deposit' and $loginid;

                my $max_balance_before_topup = BOM::Config::payment_agent()->{minimum_topup_balance}->{DEFAULT};

                return create_error_future(
                    'DemoTopupBalance',
                    {
                        override_code => $error_code,
                        params        => [$mt5_currency, formatnumber('amount', $mt5_currency, $max_balance_before_topup)]}
                ) if ($setting->{balance} > $max_balance_before_topup);

                if (_throttle($mt5_loginid)) {
                    return create_error_future('DemoTopupThrottle', {override_code => $error_code});
                }

                return Future->done({top_up_virtual => 1});

            }

            return create_error_future('MissingID', {override_code => $error_code}) unless $loginid;

            return create_error_future('MissingAmount', {override_code => $error_code}) unless $amount;

            return create_error_future('WrongAmount', {override_code => $error_code}) if ($amount <= 0);

            my $client;
            try {
                $client = BOM::User::Client->new({
                    loginid      => $loginid,
                    db_operation => 'replica'
                });
            }
            catch {

                }
                or return create_error_future(
                'InvalidLoginid',
                {
                    override_code => $error_code,
                    params        => $loginid
                });

            # Validate the binary client
            my ($err, $params) = _validate_client($client, $mt5_lc);
            return create_error_future(
                $err,
                {
                    override_code => $error_code,
                    params        => $params
                }) if $err;

            my $client_currency = $client->account ? $client->account->currency_code() : undef;
            my $brand = Brands->new(name => request()->brand);

            $err = BOM::RPC::v3::Cashier::validate_amount($amount, $client_currency);
            return create_error_future($error_code, {message => $err}) if $err;

            # master groups are real\svg_mamm_master and
            return create_error_future('NoManagerAccountWithdraw', {override_code => $error_code})

                if ($action eq 'withdrawal' and ($mt5_group // '') =~ /^real\\[a-z]*_mamm(?:_[a-z]*)?_master$/);

            # check for fully authenticated only if it's not gaming account
            # as of now we only support gaming for binary brand, in future if we
            # support for champion please revisit this
            return create_error_future('AuthenticateAccount', {override_code => $error_code})
                if ($action eq 'withdrawal'
                and ($mt5_group // '') !~ /^real\\svg/
                and not $client->fully_authenticated);

            return create_error_future(
                'WithdrawalLocked',
                {
                    override_code => $error_code,
                    params        => $brand->emails('support')})
                if ($action eq 'deposit'
                and ($client->status->no_withdrawal_or_trading or $client->status->withdrawal_locked));

            # Actual USD or EUR amount that will be deposited into the MT5 account.
            # We have a currency conversion fees when transferring between currencies.
            my $mt5_amount = undef;
            my ($min, $max) = (1, 20000);

            my $source_currency = $client_currency;

            my $mt5_currency_type    = LandingCompany::Registry::get_currency_type($mt5_currency);
            my $source_currency_type = LandingCompany::Registry::get_currency_type($source_currency);

            return create_error_future('TransferSuspended', {override_code => $error_code})
                if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
                and (($source_currency_type // '') ne ($mt5_currency_type // ''));

            my $fees                    = 0;
            my $fees_percent            = 0;
            my $fees_in_client_currency = 0;    #when a withdrawal is done record the fee in the local amount
            my ($min_fee, $fee_calculated_by_percent);

            if ($client_currency eq $mt5_currency) {
                $mt5_amount = $amount;
            } else {

                # we don't allow transfer between these two currencies
                my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;

                return create_error_future(
                    'CurrencySuspended',
                    {
                        override_code => $error_code,
                        params        => [$source_currency, $mt5_currency]}
                ) if first { $_ eq $source_currency or $_ eq $mt5_currency } @$disabled_for_transfer_currencies;

                if ($action eq 'deposit') {

                    try {

                        $min = convert_currency(1,     'USD', $client_currency);
                        $max = convert_currency(20000, 'USD', $client_currency);

                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $client_currency, $mt5_currency);

                        $mt5_amount = financialrounding('amount', $mt5_currency, $mt5_amount);
                    }

                    catch {
                        # usually we get here when convert_currency() fails to find a rate within $rate_expiry, $mt5_amount is too low, or no transfer fee are defined (invalid currency pair).
                        $err        = $_;
                        $mt5_amount = undef;
                    };

                } elsif ($action eq 'withdrawal') {

                    try {

                        $source_currency = $mt5_currency;

                        $min = convert_currency(1,     'USD', $mt5_currency);
                        $max = convert_currency(20000, 'USD', $mt5_currency);

                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $mt5_currency, $client_currency);

                        $mt5_amount = financialrounding('amount', $client_currency, $mt5_amount);

                        # if last rate is expiered calculate_to_amount_with_fees would fail.
                        $fees_in_client_currency =
                            financialrounding('amount', $client_currency, convert_currency($fees, $mt5_currency, $client_currency));
                    }
                    catch {
                        # same as previous catch
                        $err = $_;
                    };
                }
            }

            if ($err) {
                return create_error_future('NoExchangeRates', {override_code => $error_code})
                    if ($err =~ /No rate available to convert/);

                return create_error_future(
                    'NoTransferFee',
                    {
                        override_code => $error_code,
                        params        => [$client_currency, $mt5_currency]}) if ($err =~ /No transfer fee/);

                # Lower than min_unit in the receiving currency. The lower-bounds are not uptodate, otherwise we should not accept the amount in sending currency.
                # To update them, transfer_between_accounts_fees is called again with force_refresh on.
                return create_error_future(
                    'AmountNotAllowed',
                    {
                        override_code => $error_code,
                        params => [BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{$source_currency}->{min}, $source_currency]}
                ) if ($err =~ /The amount .* is below the minimum allowed amount/);

                #default error:
                return create_error_future($error_code);
            }

            return create_error_future(
                'InvalidMinAmount',
                {
                    override_code => $error_code,
                    params        => [$source_currency, formatnumber('amount', $source_currency, $min)]}
            ) if $amount < financialrounding('amount', $source_currency, $min);

            return create_error_future(
                'InvalidMaxAmount',
                {
                    override_code => $error_code,
                    params        => [$source_currency, formatnumber('amount', $source_currency, $max)]}
            ) if $amount > financialrounding('amount', $source_currency, $max);

            return Future->done({
                mt5_amount              => $mt5_amount,
                fees                    => $fees,
                fees_currency           => $source_currency,
                fees_percent            => $fees_percent,
                fees_in_client_currency => $fees_in_client_currency,
                mt5_currency_code       => $mt5_currency,
                min_fee                 => $min_fee,
                calculated_fee          => $fee_calculated_by_percent,
                mt5_data                => $setting
            });
        });
}

sub _fetch_mt5_lc {
    my $settings = shift;

    my $lc_short;

    # This extracts the landing company name from the mt5 group name
    # E.g. real\labuan -> labuan , real\vanuatu_standard -> vanuatu, real\svg_standard -> svg

    if ($settings->{group} =~ m/[a-zA-Z]+\\([a-zA-Z]+)($|_.+)/) {
        $lc_short = $1;
    }

    # check if lc exists
    return create_error_future('InvalidMT5Group') unless $lc_short and LandingCompany::Registry::get($lc_short);

    return $lc_short;
}

sub _mt5_has_open_positions {
    my $login = shift;

    return BOM::MT5::User::Async::get_open_positions_count($login)->then(
        sub {
            my ($response) = @_;
            return create_error_future('CannotGetOpenPositions')
                if (ref $response eq 'HASH' and $response->{error});

            return Future->done($response->{total} ? 1 : 0);
        });
}

sub _notify_for_locked_mt5 {
    my ($client, $mt5_login) = @_;
    my $brand = Brands->new(name => request()->brand);
    my $msg = "${\$client->loginid} MT5 Account MT$mt5_login is locked, balance is below 0.";

    try {
        send_email({
            from                  => $brand->emails('system'),
            to                    => $brand->emails('support'),
            subject               => 'MT5 Withdrawal Locked',
            message               => [$msg],
            use_email_template    => 0,
            email_content_is_html => 0,
        });
    }
    catch {
        warn "Failed to notify cs team about MT5 locked account MT$mt5_login";
    };
    return 1;
}

=head2 _record_mt5_transfer

Writes an entry into the mt5_transfer table
Takes the following arguments as named parameters

=over 4

=item * DBIC  Database handle
=item * payment_id Primary key of the payment table entry
=item * mt5_amount   Amount sent to MT5 in the MT5 currency
=item * mt5_account_id the clients MT5 account id
=item * mt5_currency_code  Currency Code of the lcients MT5 account.

=back

Returns 1

=cut

sub _record_mt5_transfer {
    my ($dbic, $payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code) = @_;

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                'INSERT INTO payment.mt5_transfer
            (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
            VALUES (?,?,?,?)'
            );
            $sth->execute($payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code);
        });
    return 1;
}

sub _store_transaction_redis {
    my $data = shift;
    BOM::Platform::Event::Emitter::emit('store_mt5_transaction', $data);
    return;
}

=head2 _validate_client

Validate the client account, which is involved in real-money deposit/withdrawal

=cut

sub _validate_client {
    my ($client_obj, $mt5_lc) = @_;

    my $loginid = $client_obj->loginid;

    # only for real money account
    return 'permission' if ($client_obj->is_virtual);

    my $lc = $client_obj->landing_company->short;

    # Landing companies listed below are an exception for this check as
    # they have mutual agreement and it is allowed to transfer funds
    # through gaming/financial MT5 accounts:
    # - transfers between maltainvest and malta
    # - svg, vanuatu, and labuan

    unless (($lc eq 'svg' and ($mt5_lc eq 'vanuatu' or $mt5_lc eq 'labuan'))
        or ($lc eq 'maltainvest' and $mt5_lc eq 'malta')
        or ($lc eq 'malta'       and $mt5_lc eq 'maltainvest')
        or $mt5_lc eq $lc)
    {
        # Otherwise, Financial accounts should not be able to deposit to, or withdraw from, gaming MT5
        return 'SwitchAccount';
    }

    # Deposits and withdrawals are blocked for non-authenticated MF clients
    return 'AuthenticateAccount'
        if ($lc eq 'maltainvest' and not $client_obj->fully_authenticated);

    return ('AccountDisabled', $loginid) if ($client_obj->status->disabled);

    return ('CashierLocked', $loginid)
        if ($client_obj->status->cashier_locked || $client_obj->documents_expired);

    my $client_currency = $client_obj->account ? $client_obj->account->currency_code() : undef;
    return ('SetExistingAccountCurrency', $loginid) unless $client_currency;

    my $daily_transfer_limit  = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5;
    my $client_today_transfer = $client_obj->get_today_transfer_summary('mt5_transfer');

    return ('MaximumTransfers', $daily_transfer_limit)
        unless $client_today_transfer->{count} < $daily_transfer_limit;

    return undef;
}

sub _is_account_demo {
    my ($group) = @_;
    return $group =~ /demo/;
}

sub do_mt5_deposit {
    my ($login, $amount, $comment, $txn_id) = @_;
    my $deposit_sub = \&BOM::MT5::User::Async::deposit;
    if (!_is_mt5_suspended('manager_api')) {
        $deposit_sub = \&BOM::MT5::User::Async::manager_api_deposit;
    }

    return $deposit_sub->({
        login   => $login,
        amount  => $amount,
        comment => $comment,
        txn_id  => $txn_id,
    });
}

sub do_mt5_withdrawal {
    my ($login, $amount, $comment) = @_;
    my $withdrawal_sub = \&BOM::MT5::User::Async::withdrawal;
    if (!_is_mt5_suspended('manager_api')) {
        $withdrawal_sub = \&BOM::MT5::User::Async::manager_api_withdrawal;
    }

    return $withdrawal_sub->({
        login   => $login,
        amount  => $amount,
        comment => $comment,
    });
}

sub _generate_password {
    my ($seed_str) = @_;
    # The password must contain at least two of three types of characters (lower case, upper case and digits)
    # We are not using random string for future usage consideration
    my $pwd = substr(sha384_hex($seed_str . 'E3xsTE6BQ=='), 0, 20);
    return $pwd . 'Hx_0';
}

1;

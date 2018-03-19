
=head1 BOM::RPC::v3::Accounts

This package contains methods for Account entities in our system.

=cut

package BOM::RPC::v3::Accounts;

use 5.014;
use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Try::Tiny;
use WWW::OneAll;
use Date::Utility;
use HTML::Entities qw(encode_entities);
use List::Util qw(any sum0);

use Brands;
use BOM::User::Client;
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::Japan::NewAccount;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale qw/get_state_by_id/;
use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Token;
use BOM::Transaction;
use BOM::Platform::Config;
use BOM::Platform::Password;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Model::AccessToken;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::Model::OAuth;
use BOM::Database::Model::UserConnect;
use BOM::Platform::Runtime;

my $allowed_fields_for_virtual = qr/passthrough|set_settings|email_consent|residence|allow_copiers/;

my $json = JSON::MaybeXS->new;

requires_auth();

=head2 payout_currencies

    [$currency, @lc_currencies] = payout_currencies({
        landing_company_name => $lc_name,
        token_details        => {loginid => $loginid},
    })

Returns an arrayref containing the following:

=over 4

=item * A payout currency that is valid for a specific client

=item * Multiple valid payout currencies for the landing company if a client is not provided.

=back

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * landing_company_name

=item * token_details, which may contain the following keys:

=over 4

=item * loginid

=back

=back

Returns a sorted arrayref of valid payout currencies

=cut

rpc "payout_currencies",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $token_details = $params->{token_details};
    my $client;
    if ($token_details and exists $token_details->{loginid}) {
        $client = BOM::User::Client->new({
            loginid      => $token_details->{loginid},
            db_operation => 'replica'
        });
    }

    # If the client has a default_account, he has already chosen his currency.
    # The client's currency is returned in this case.
    return [$client->currency] if $client && $client->default_account;

    # If the client has not yet selected currency - we will use list from his landing company
    # or we may have a landing company even if we're not logged in - typically this
    # is obtained from the GeoIP country code lookup. If we have one, use it.
    my $lc = $client ? $client->landing_company : LandingCompany::Registry::get($params->{landing_company_name} || 'costarica');

    # ... but we fall back to Costa Rica as a useful default, since it has most
    # currencies enabled.

    # Remove cryptocurrencies that have been suspended
    return BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);
    };

rpc "landing_company",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $country  = $params->{args}->{landing_company};
    my $configs  = Brands->new(name => request()->brand)->countries_instance->countries_list;
    my $c_config = $configs->{$country};
    unless ($c_config) {
        ($c_config) = grep { $configs->{$_}->{name} eq $country and $country = $_ } keys %$configs;
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnknownLandingCompany',
            message_to_client => localize('Unknown landing company.')}) unless $c_config;

    # BE CAREFUL, do not change ref since it's persistent
    my %landing_company = %{$c_config};

    $landing_company{id} = $country;
    my $registry = LandingCompany::Registry->new;

    foreach my $type ('gaming_company', 'financial_company', 'mt_gaming_company', 'mt_financial_company') {
        if (($landing_company{$type} // '') ne 'none') {
            $landing_company{$type} = __build_landing_company($registry->get($landing_company{$type}));
        } else {
            delete $landing_company{$type};
        }
    }

    return \%landing_company;
    };

=head2 landing_company_details

    $landing_company_details = landing_company_details({
        landing_company_name => $lc,
    })

Returns the details of a landing_company object.

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * args, which may contain the following keys:

=over 4

=item * landing_company_details

=back

=back

Returns a hashref containing the keys from __build_landing_company($lc)

=cut

rpc "landing_company_details",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $lc = LandingCompany::Registry::get($params->{args}->{landing_company_details});
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnknownLandingCompany',
            message_to_client => localize('Unknown landing company.')}) unless $lc;

    return __build_landing_company($lc);
    };

=head2 __build_landing_company

    $landing_company_details = __build_landing_company($lc)

Returns a hashref containing the following:

=over 4

=item * shortcode

=item * name

=item * address

=item * country

=item * legal_default_currency

=item * legal_allowed_currencies

=item * legal_allowed_markets

=item * legal_allowed_contract_categories

=item * has_reality_check

=back

Takes a single C<$lc> object that contains the following methods:

=over 4

=item * short

=item * name

=item * address

=item * country

=item * legal_default_currency

=item * legal_allowed_markets

=item * legal_allowed_contract_categories

=item * has_reality_check

=back

Returns a hashref of landing_company parameters

=cut

sub __build_landing_company {
    my ($lc) = @_;

    # Get suspended currencies and remove them from list of legal currencies
    my $payout_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);

    return {
        shortcode                         => $lc->short,
        name                              => $lc->name,
        address                           => $lc->address,
        country                           => $lc->country,
        legal_default_currency            => $lc->legal_default_currency,
        legal_allowed_currencies          => $payout_currencies,
        legal_allowed_markets             => $lc->legal_allowed_markets,
        legal_allowed_contract_categories => $lc->legal_allowed_contract_categories,
        has_reality_check                 => $lc->has_reality_check ? 1 : 0
    };
}

rpc statement => sub {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')});
    }
    my $client  = $params->{client};
    my $account = $client->default_account;
    return {
        transactions => [],
        count        => 0
    } unless ($account);

    BOM::RPC::v3::PortfolioManagement::_sell_expired_contracts($client, $params->{source});

    my $results = BOM::Database::DataMapper::Transaction->new({db => $account->db})->get_transactions_ws($params->{args}, $account);
    return {
        transactions => [],
        count        => 0
    } unless (scalar @{$results});

    my @short_codes = map { $_->{short_code} } grep { defined $_->{short_code} } @{$results};

    my $longcodes;
    $longcodes = BOM::RPC::v3::Utility::longcode({
            short_codes => \@short_codes,
            currency    => $account->currency_code,
            language    => $params->{language},
            source      => $params->{source},
        }) if $params->{args}->{description} and @short_codes;

    my @txns;
    for my $txn (@$results) {
        my $struct = {
            transaction_id => $txn->{id},
            reference_id   => $txn->{buy_tr_id},
            amount         => $txn->{amount},
            action_type    => $txn->{action_type},
            balance_after  => formatnumber('amount', $account->currency_code, $txn->{balance_after}),
            contract_id    => $txn->{financial_market_bet_id},
            payout         => $txn->{payout_price},
        };

        my $txn_time;
        if (exists $txn->{financial_market_bet_id} and $txn->{financial_market_bet_id}) {
            if ($txn->{action_type} eq 'sell') {
                $struct->{purchase_time} = Date::Utility->new($txn->{purchase_time})->epoch;
                $txn_time = $txn->{sell_time};
            } else {
                $txn_time = $txn->{purchase_time};
            }
        } else {
            $txn_time = $txn->{payment_time};
        }
        $struct->{transaction_time} = Date::Utility->new($txn_time)->epoch;
        $struct->{app_id} = BOM::RPC::v3::Utility::mask_app_id($txn->{source}, $txn_time);

        if ($params->{args}->{description}) {
            $struct->{shortcode} = $txn->{short_code} // '';
            if ($struct->{shortcode}) {
                $struct->{longcode} = $longcodes->{longcodes}->{$struct->{shortcode}} // localize('Could not retrieve contract details');
            } else {
                $struct->{longcode} //= $txn->{payment_remark} // '';
            }
        }
        push @txns, $struct;
    }

    return {
        transactions => [@txns],
        count        => scalar @txns
    };
};

rpc profit_table => sub {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')});
    }

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return {
        transactions => [],
        count        => 0
    } unless ($client);

    BOM::RPC::v3::PortfolioManagement::_sell_expired_contracts($client, $params->{source});

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client_loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client_loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    my $args = $params->{args};
    $args->{after}  = $args->{date_from} if $args->{date_from};
    $args->{before} = $args->{date_to}   if $args->{date_to};
    my $data = $fmb_dm->get_sold_bets_of_account($args);
    return {
        transactions => [],
        count        => 0
    } unless (scalar @{$data});
    # args is passed to echo req hence we need to delete them
    delete $args->{after};
    delete $args->{before};

    my @short_codes = map { $_->{short_code} } @{$data};

    my $res;
    $res = BOM::RPC::v3::Utility::longcode({
            short_codes => \@short_codes,
            currency    => $client->currency,
            language    => $params->{language},
            source      => $params->{source},
        }) if $args->{description} and @short_codes;

    ## remove useless and plus new
    my @transactions;
    foreach my $row (@{$data}) {
        my %trx = map { $_ => $row->{$_} } (qw/sell_price buy_price/);
        $trx{contract_id}    = $row->{id};
        $trx{transaction_id} = $row->{txn_id};
        $trx{payout}         = $row->{payout_price};
        $trx{purchase_time}  = Date::Utility->new($row->{purchase_time})->epoch;
        $trx{sell_time}      = Date::Utility->new($row->{sell_time})->epoch;
        $trx{app_id}         = BOM::RPC::v3::Utility::mask_app_id($row->{source}, $row->{purchase_time});

        if ($args->{description}) {
            $trx{shortcode} = $row->{short_code};
            $trx{longcode} = $res->{longcodes}->{$row->{short_code}} // localize('Could not retrieve contract details');
        }

        push @transactions, \%trx;
    }

    return {
        transactions => \@transactions,
        count        => scalar(@transactions)};
};

=head2 balance

    my $balance_obj = balance({ client => $client });

Returns balance for the default account of the client. If there is no default account,
balance as 0.00 with empty string as currency type is returned.

Takes the following (named) parameters:

=over 4

=item * C<params> - A hashref with reference to BOM::User::Client object under the key C<client>

=back

Returns a hashref with following items

=over 4

=item * C<loginid> - Login ID for the default account. E.g. : CR90000000

=item * C<currency> - Currency in which the balance is being represented. E.g. : BTC

=item * C<balance> - Balance for the default account. E.g. : 100.00
 
=cut

rpc balance => sub {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return {
        currency => '',
        loginid  => $client_loginid,
        balance  => "0.00"
    } unless ($client->default_account);

    return {
        loginid  => $client_loginid,
        currency => $client->default_account->currency_code,
        balance  => formatnumber('amount', $client->default_account->currency_code, $client->default_account->balance)};
};

rpc get_account_status => sub {
    my $params = shift;

    my $client = $params->{client};
    my $already_unwelcomed;
    my @status;
    foreach my $s (sort keys %{$client->client_status_types}) {
        next if $s eq 'tnc_approval';    # the useful part for tnc_approval is reason
        if ($client->get_status($s)) {
            push @status, $s;
            $already_unwelcomed = 1 if $s eq 'unwelcome';
        }
    }

    push @status, 'authenticated' if ($client->client_fully_authenticated);
    my $risk_classification = $client->aml_risk_classification // '';

    # we need to send only low, standard, high as manual override is for internal purpose
    $risk_classification =~ s/manual override - //;

    # differentiate between social and password based accounts
    my $user = BOM::User->new({email => $client->email});
    push @status, 'unwelcome' if not $already_unwelcomed and BOM::Transaction::Validation->new({clients => [$client]})->check_trade_status($client);

    push @status, 'social_signup' if $user->has_social_signup;
    # check whether the user need to perform financial assessment
    my $financial_assessment = $client->financial_assessment();
    $financial_assessment = ref($financial_assessment) ? $json->decode($financial_assessment->data || '{}') : {};
    push @status,
        'financial_assessment_not_complete'
        if (
        any { !length $financial_assessment->{$_}->{answer} }
        keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});

    my $prompt_client_to_authenticate = 0;
    my $shortcode                     = $client->landing_company->short;
    my $authentication_in_progress    = $client->get_status('document_needs_action') || $client->get_status('document_under_review');
    if ($client->client_fully_authenticated) {
        # Authenticated clients still need to go through age verification checks for IOM/MF/MLT
        if (any { $shortcode eq $_ } qw(iom malta maltainvest)) {
            $prompt_client_to_authenticate = 1 unless $client->get_status('age_verification');
        }
    } elsif ($authentication_in_progress) {
        $prompt_client_to_authenticate = 1;
    } else {
        if ($shortcode eq 'costarica' or $shortcode eq 'champion') {
            # Our threshold is 4000 USD, but we want to include total across all the user's currencies
            my $total = sum0(
                map { in_USD($_->default_account->balance, $_->currency) }
                grep { $_->default_account && $_->landing_company->short eq $shortcode } $user->clients
            );
            if ($total > 4000) {
                $prompt_client_to_authenticate = 1;
            }
        } elsif ($shortcode eq 'virtual') {
            # No authentication for virtual accounts - set this explicitly in case we change the default above
            $prompt_client_to_authenticate = 0;
        } else {
            # Authentication required for all regulated companies, including JP - we'll handle this on the frontend
            $prompt_client_to_authenticate = 1;
        }
    }

    return {
        status                        => \@status,
        prompt_client_to_authenticate => $prompt_client_to_authenticate,
        risk_classification           => $risk_classification
    };
};

rpc change_password => sub {
    my $params = shift;

    my $client = $params->{client};
    my ($token_type, $client_ip, $args) = @{$params}{qw/token_type client_ip args/};

    # allow OAuth token
    unless (($token_type // '') eq 'oauth_token') {
        return BOM::RPC::v3::Utility::permission_error();
    }

    # Fetch user by loginid, if the user doesn't exist or
    # has no associated clients then throw exception
    my $user = BOM::User->new({loginid => $client->loginid});
    my @clients;
    if (not $user or not @clients = $user->clients) {
        return BOM::RPC::v3::Utility::client_error();
    }

    # do not allow social based clients to reset password
    return BOM::RPC::v3::Utility::create_error({
            code              => "SocialBased",
            message_to_client => localize("Sorry, your account does not allow passwords because you use social media to log in.")}
    ) if $user->has_social_signup;

    if (
        my $pass_error = BOM::RPC::v3::Utility::_check_password({
                old_password => $args->{old_password},
                new_password => $args->{new_password},
                user_pass    => $user->password
            }))
    {
        return $pass_error;
    }

    my $new_password = BOM::Platform::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    my $oauth = BOM::Database::Model::OAuth->new;
    for my $obj (@clients) {
        $obj->password($new_password);
        $obj->save;
        $oauth->revoke_tokens_by_loginid($obj->loginid);
    }

    BOM::Platform::AuditLog::log('password has been changed', $client->email);
    send_email({
            from    => Brands->new(name => request()->brand)->emails('support'),
            to      => $client->email,
            subject => localize('Your password has been changed.'),
            message => [
                localize(
                    'The password for your account [_1] has been changed. This request originated from IP address [_2]. If this request was not performed by you, please immediately contact Customer Support.',
                    $client->email,
                    $client_ip
                )
            ],
            use_email_template    => 1,
            email_content_is_html => 1,
            template_loginid      => $client->loginid,
        });

    return {status => 1};
};

rpc cashier_password => sub {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my ($client_ip, $args) = @{$params}{qw/client_ip args/};
    my $unlock_password = $args->{unlock_password} // '';
    my $lock_password   = $args->{lock_password}   // '';

    unless (length($unlock_password) || length($lock_password)) {
        # just return status
        if (length $client->cashier_setting_password) {
            return {status => 1};
        } else {
            return {status => 0};
        }
    }

    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CashierPassword',
            message_to_client => $error,
        });
    };

    if (length($lock_password)) {
        # lock operation
        if (length $client->cashier_setting_password) {
            return $error_sub->(localize('Your cashier was locked.'));
        }

        my $user = BOM::User->new({email => $client->email});
        if (BOM::Platform::Password::checkpw($lock_password, $user->password)) {
            return $error_sub->(localize('Please use a different password than your login password.'));
        }

        if (my $pass_error = BOM::RPC::v3::Utility::_check_password({new_password => $lock_password})) {
            return $pass_error;
        }

        $client->cashier_setting_password(BOM::Platform::Password::hashpw($lock_password));
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Cashier password updated"),
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template'    => 1,
                    'email_content_is_html' => 1,
                    template_loginid        => $client->loginid,
                });
            return {status => 1};
        }
    } else {
        # unlock operation
        unless (length $client->cashier_setting_password) {
            return $error_sub->(localize('Your cashier was not locked.'));
        }

        my $cashier_password = $client->cashier_setting_password;
        if (!BOM::Platform::Password::checkpw($unlock_password, $cashier_password)) {
            BOM::Platform::AuditLog::log('Failed attempt to unlock cashier', $client->loginid);
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Failed attempt to unlock cashier section"),
                    'message' => [
                        localize(
                            'This is an automated message to alert you to the fact that there was a failed attempt to unlock the Cashier/Settings section of your account [_1] from IP address [_2]',
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template'    => 1,
                    'email_content_is_html' => 1,
                    template_loginid        => $client->loginid,
                });

            return $error_sub->(localize('Sorry, you have entered an incorrect cashier password'));
        }

        $client->cashier_setting_password('');
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your account.'));
        } else {
            send_email({
                    'from'    => Brands->new(name => request()->brand)->emails('support'),
                    'to'      => $client->email,
                    'subject' => localize("Cashier password updated"),
                    'message' => [
                        localize(
                            "This is an automated message to alert you that a change was made to your cashier settings section of your account [_1] from IP address [_2]. If you did not perform this update please login to your account and update settings.",
                            $client->loginid,
                            $client_ip
                        )
                    ],
                    'use_email_template'    => 1,
                    'email_content_is_html' => 1,
                    template_loginid        => $client->loginid,
                });
            BOM::Platform::AuditLog::log('cashier unlocked', $client->loginid);
            return {status => 0};
        }
    }
};

rpc "reset_password",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;
    my $args   = $params->{args};
    my $email  = BOM::Platform::Token->new({token => $args->{verification_code}})->email;
    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'reset_password')->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    my $user = BOM::User->new({email => $email});
    my @clients = ();
    if (not $user or not @clients = $user->clients) {
        return BOM::RPC::v3::Utility::client_error();
    }

    # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
    my $client = $clients[0];

    # do not allow social based clients to reset password
    return BOM::RPC::v3::Utility::create_error({
            code              => "SocialBased",
            message_to_client => localize('Sorry, you cannot reset your password because you logged in using a social network.'),
        }) if $user->has_social_signup;

    unless ($client->is_virtual) {
        unless ($args->{date_of_birth}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => "DateOfBirthMissing",
                    message_to_client => localize("Date of birth is required.")});
        }
        my $user_dob = $args->{date_of_birth} =~ s/-0/-/gr;    # / (dummy ST3)
        my $db_dob   = $client->date_of_birth =~ s/-0/-/gr;    # /

        return BOM::RPC::v3::Utility::create_error({
                code              => "DateOfBirthMismatch",
                message_to_client => localize("The email address and date of birth do not match.")}) if ($user_dob ne $db_dob);
    }

    if (my $pass_error = BOM::RPC::v3::Utility::_check_password({new_password => $args->{new_password}})) {
        return $pass_error;
    }

    my $new_password = BOM::Platform::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    my $oauth = BOM::Database::Model::OAuth->new;
    for my $obj (@clients) {
        $obj->password($new_password);
        $obj->save;
        $oauth->revoke_tokens_by_loginid($obj->loginid);
    }

    BOM::Platform::AuditLog::log('password has been reset', $email, $args->{verification_code});
    send_email({
            from    => Brands->new(name => request()->brand)->emails('support'),
            to      => $email,
            subject => localize('Your password has been reset.'),
            message => [
                localize(
                    'The password for your account [_1] has been reset. If this request was not performed by you, please immediately contact Customer Support.',
                    $email
                )
            ],
            use_email_template    => 1,
            email_content_is_html => 1,
            template_loginid      => $client->loginid,
        });

    return {status => 1};
    };

rpc get_settings => sub {
    my $params = shift;

    my $client = $params->{client};

    my ($dob_epoch, $country_code, $country);
    $dob_epoch = Date::Utility->new($client->date_of_birth)->epoch if ($client->date_of_birth);
    if ($client->residence) {
        $country_code = $client->residence;
        $country =
            Brands->new(name => request()->brand)->countries_instance->countries->localized_code2country($client->residence, $params->{language});
    }

    my $client_tnc_status = $client->get_status('tnc_approval');

    # get JP real a/c status, for Japan Virtual a/c client
    my $jp_account_status;
    $jp_account_status = BOM::RPC::v3::Japan::NewAccount::get_jp_account_status($client) if ($client->landing_company->short eq 'japan-virtual');

    # get Japan specific a/c details (eg: daily loss, occupation, trading experience), for Japan real a/c client
    my $jp_real_settings;
    $jp_real_settings = BOM::RPC::v3::Japan::NewAccount::get_jp_settings($client) if ($client->landing_company->short eq 'japan');

    return {
        email         => $client->email,
        country       => $country,
        country_code  => $country_code,
        email_consent => do { my $user = BOM::User->new({email => $client->email}); ($user && $user->email_consent) ? 1 : 0 },
        (
            $client->is_virtual
            ? ()
            : (
                salutation                     => $client->salutation,
                first_name                     => $client->first_name,
                last_name                      => $client->last_name,
                date_of_birth                  => $dob_epoch,
                address_line_1                 => $client->address_1,
                address_line_2                 => $client->address_2,
                address_city                   => $client->city,
                address_state                  => $client->state,
                address_postcode               => $client->postcode,
                phone                          => $client->phone,
                allow_copiers                  => $client->allow_copiers // 0,
                is_authenticated_payment_agent => ($client->payment_agent and $client->payment_agent->is_authenticated) ? 1 : 0,
                client_tnc_status => $client_tnc_status ? $client_tnc_status->reason : '',
                place_of_birth    => $client->place_of_birth,
                tax_residence     => $client->tax_residence,
                tax_identification_number   => $client->tax_identification_number,
                account_opening_reason      => $client->account_opening_reason,
                request_professional_status => $client->get_status('professional_requested') ? 1 : 0,
            )
        ),
        $jp_account_status ? (jp_account_status => $jp_account_status) : (),
        $jp_real_settings  ? (jp_settings       => $jp_real_settings)  : (),
    };
};

rpc set_settings => sub {
    my $params = shift;

    my $client = $params->{client};

    my ($website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/website_name client_ip user_agent language args/};

    my ($residence, $allow_copiers, $jp_status) = ($args->{residence}, $args->{allow_copiers});
    if ($client->is_virtual) {
        # Virtual client can update
        # - residence, if residence not set. But not for Japan
        # - email_consent (common to real account as well)
        if (not $client->residence and $residence and $residence ne 'jp') {
            if (Brands->new(name => request()->brand)->countries_instance->restricted_country($residence)) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'InvalidResidence',
                        message_to_client => localize('Sorry, our service is not available for your country of residence.')});
            } else {
                $client->residence($residence);
                if (not $client->save()) {
                    return BOM::RPC::v3::Utility::client_error();
                }
            }
        } elsif (
            grep {
                !/$allowed_fields_for_virtual/
            } keys %$args
            )
        {
            # we only allow these keys in virtual set settings any other key will result in permission error
            return BOM::RPC::v3::Utility::permission_error();
        }
    } else {
        # real client is not allowed to update residence
        return BOM::RPC::v3::Utility::permission_error() if $residence;

        # handle Japan settings update separately
        if ($client->residence eq 'jp') {
            # this may return error or {status => 1}
            $jp_status = BOM::RPC::v3::Japan::NewAccount::set_jp_settings($params);
            return $jp_status if $jp_status->{error};
        } elsif ($client->account_opening_reason
            and $args->{account_opening_reason}
            and $args->{account_opening_reason} ne $client->account_opening_reason)
        {
            # cannot set account_opening_reason with a different value
            return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize("Value of account_opening_reason cannot be changed."),
            });
        } elsif (not $client->account_opening_reason and not $args->{account_opening_reason}) {
            # required to set account_opening_reason if empty
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InputValidationFailed',
                    message_to_client => localize("Input validation failed: account_opening_reason"),
                    details           => {
                        account_opening_reason => "is missing and it is required",
                    },
                });
        }

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize("Value of place_of_birth cannot be changed.")}
        ) if ($client->place_of_birth and $args->{place_of_birth} and $args->{place_of_birth} ne $client->place_of_birth);

        if ($client->residence eq 'gb' and defined $args->{address_postcode} and $args->{address_postcode} eq '') {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InputValidationFailed',
                    message_to_client => localize("Input validation failed: address_postcode"),
                    details           => {
                        address_postcode => "is missing and it is required",
                    },
                });
        }
    }

    return BOM::RPC::v3::Utility::permission_error()
        if $allow_copiers
        and ($client->landing_company->short ne 'costarica' and not $client->is_virtual);

    if (
        $allow_copiers
        and @{BOM::Database::DataMapper::Copier->new(
                broker_code => $client->broker_code,
                operation   => 'replica'
                )->get_traders({copier_id => $client->loginid})
                || []})
    {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AllowCopiersError',
                message_to_client => localize("Copier can't be a trader.")});
    }

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined $args->{email_consent}) {
        my $user = BOM::User->new({email => $client->email});
        $user->email_consent($args->{email_consent});
        $user->save;
    }

    # need to handle for $jp_status->{status} as that come from japan settings
    return {status => 1} if $jp_status->{status};

    my $tax_residence             = $args->{'tax_residence'}             // '';
    my $tax_identification_number = $args->{'tax_identification_number'} // '';

    return BOM::RPC::v3::Utility::create_error({
            code => 'TINDetailsMandatory',
            message_to_client =>
                localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')}
    ) if ($client->landing_company->short eq 'maltainvest' and (not $tax_residence or not $tax_identification_number));

    my $now             = Date::Utility->new;
    my $address1        = $args->{'address_line_1'} // $client->address_1;
    my $address2        = ($args->{'address_line_2'} // $client->address_2) // '';
    my $addressTown     = $args->{'address_city'} // $client->city;
    my $addressState    = ($args->{'address_state'} // $client->state) // '';
    my $addressPostcode = $args->{'address_postcode'} // $client->postcode;
    my $phone           = ($args->{'phone'} // $client->phone) // '';
    my $birth_place     = $args->{place_of_birth} // $client->place_of_birth;

    my $cil_message;
    if (   ($address1 and $address1 ne $client->address_1)
        or $address2 ne $client->address_2
        or $addressTown ne $client->city
        or $addressState ne $client->state
        or $addressPostcode ne $client->postcode)
    {
        my $authenticated = $client->client_fully_authenticated;
        $cil_message =
              ($authenticated ? 'Authenticated' : 'Non-authenticated')
            . ' client ['
            . $client->loginid
            . '] updated his/her address from ['
            . join(' ', $client->address_1, $client->address_2, $client->city, $client->state, $client->postcode)
            . '] to ['
            . join(' ', ($address1 // ''), $address2, $addressTown, $addressState, $addressPostcode) . ']';
    }

    # only allowed to set for maltainvest, costarica and only
    # if professional status is not set or requested
    my $update_professional_status = sub {
        my ($client_obj) = @_;
        if (    $args->{request_professional_status}
            and $client_obj->landing_company->short =~ /^(?:costarica|maltainvest)$/
            and not($client_obj->get_status('professional') or $client_obj->get_status('professional_requested')))
        {
            $client_obj->set_status('professional_requested', 'SYSTEM', 'Professional account requested');
            return 1;
        }
        return undef;
    };

    my $user = BOM::User->new({email => $client->email});
    foreach my $cli ($user->clients) {
        next if $cli->is_virtual;

        $cli->address_1($address1);
        $cli->address_2($address2);
        $cli->city($addressTown);
        $cli->state($addressState) if defined $addressState;                       # FIXME validate
        $cli->postcode($addressPostcode) if defined $args->{'address_postcode'};
        $cli->phone($phone);
        $cli->place_of_birth($birth_place);
        $cli->account_opening_reason($args->{account_opening_reason}) unless $cli->account_opening_reason;

        $cli->latest_environment($now->datetime . ' ' . $client_ip . ' ' . $user_agent . ' LANG=' . $language);

        # As per CRS/FATCA regulatory requirement we need to
        # save this information as client status, so updating
        # tax residence and tax number will create client status
        # as we have database trigger for that now
        if ((
                   $tax_residence
                or $tax_identification_number
            )
            and (  ($cli->tax_residence // '') ne $tax_residence
                or ($cli->tax_identification_number // '') ne $tax_identification_number))
        {
            $cli->tax_residence($tax_residence)                         if $tax_residence;
            $cli->tax_identification_number($tax_identification_number) if $tax_identification_number;
        }

        my $set_status = $update_professional_status->($cli);

        if (not $cli->save()) {
            return BOM::RPC::v3::Utility::client_error();
        }

        BOM::RPC::v3::Utility::send_professional_requested_email($cli->loginid, $cli->residence) if ($set_status);
    }
    # update client value after latest changes
    $client = BOM::User::Client->new({loginid => $client->loginid});

    # only allow current client to set allow_copiers
    if (defined $allow_copiers) {
        $client->allow_copiers($allow_copiers);
    }
    if (not $client->save()) {
        return BOM::RPC::v3::Utility::client_error();
    }

    if ($cil_message) {
        $client->add_note('Update Address Notification', $cil_message);
    }

    my $message = localize(
        'Dear [_1] [_2] [_3],',
        map { encode_entities($_) } BOM::Platform::Locale::translate_salutation($client->salutation),
        $client->first_name, $client->last_name
    ) . "\n\n";
    $message .= localize('Please note that your settings have been updated as follows:') . "\n\n";

    # lookup state name by id
    my $lookup_state =
        ($client->state and $client->residence)
        ? BOM::Platform::Locale::get_state_by_id($client->state, $client->residence) // ''
        : '';
    my @address_fields = ((map { $client->$_ } qw/address_1 address_2 city/), $lookup_state, $client->postcode);
    # filter out empty fields
    my $full_address = join ', ', grep { defined $_ and /\S/ } @address_fields;

    my $residence_country = Locale::Country::code2country($client->residence);
    my @updated_fields    = (
        [localize('Email address'),        $client->email],
        [localize('Country of Residence'), $residence_country],
        [localize('Address'),              $full_address],
        [localize('Telephone'),            $client->phone]);

    my $tr_tax_residence = join ', ', map { Locale::Country::code2country($_) } split /,/, ($client->tax_residence || '');

    push @updated_fields,
        (
        [localize('Place of birth'), $client->place_of_birth ? Locale::Country::code2country($client->place_of_birth) : ''],
        [localize("Tax residence"), $tr_tax_residence],
        [localize('Tax identification number'), ($client->tax_identification_number || '')],
        );
    push @updated_fields,
        [localize('Receive news and special offers'), BOM::User->new({email => $client->email})->email_consent ? localize("Yes") : localize("No")]
        if exists $args->{email_consent};
    push @updated_fields, [localize('Allow copiers'), $client->allow_copiers ? localize("Yes") : localize("No")]
        if defined $allow_copiers;
    push @updated_fields,
        [
        localize('Requested professional status'),
        (
                   $args->{request_professional_status}
                or $client->get_status('professional_requested')
        ) ? localize("Yes") : localize("No")];

    $message .= "<table>";
    foreach my $updated_field (@updated_fields) {
        $message .=
              '<tr><td style="vertical-align:top; text-align:left;"><strong>'
            . encode_entities($updated_field->[0])
            . '</strong></td><td style="vertical-align:top;">:&nbsp;</td><td style="vertical-align:top;text-align:left;">'
            . encode_entities($updated_field->[1])
            . '</td></tr>';
    }
    $message .= '</table>';
    $message .= "\n" . localize('The [_1] team.', $website_name);

    send_email({
        from                  => Brands->new(name => request()->brand)->emails('support'),
        to                    => $client->email,
        subject               => $client->loginid . ' ' . localize('Change in account settings'),
        message               => [$message],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => $client->loginid,
    });
    BOM::Platform::AuditLog::log('Your settings have been updated successfully', $client->loginid);

    return {status => 1};
};

rpc get_self_exclusion => sub {
    my $params = shift;

    my $client = $params->{client};
    return _get_self_exclusion_details($client);
};

sub _get_self_exclusion_details {
    my $client = shift;

    my $get_self_exclusion = {};
    return $get_self_exclusion if $client->is_virtual;

    my $self_exclusion = $client->get_self_exclusion;
    if ($self_exclusion) {
        $get_self_exclusion->{max_balance} = $self_exclusion->max_balance
            if $self_exclusion->max_balance;
        $get_self_exclusion->{max_turnover} = $self_exclusion->max_turnover
            if $self_exclusion->max_turnover;
        $get_self_exclusion->{max_open_bets} = $self_exclusion->max_open_bets
            if $self_exclusion->max_open_bets;
        $get_self_exclusion->{max_losses} = $self_exclusion->max_losses
            if $self_exclusion->max_losses;
        $get_self_exclusion->{max_7day_losses} = $self_exclusion->max_7day_losses
            if $self_exclusion->max_7day_losses;
        $get_self_exclusion->{max_7day_turnover} = $self_exclusion->max_7day_turnover
            if $self_exclusion->max_7day_turnover;
        $get_self_exclusion->{max_30day_losses} = $self_exclusion->max_30day_losses
            if $self_exclusion->max_30day_losses;
        $get_self_exclusion->{max_30day_turnover} = $self_exclusion->max_30day_turnover
            if $self_exclusion->max_30day_turnover;
        $get_self_exclusion->{session_duration_limit} = $self_exclusion->session_duration_limit
            if $self_exclusion->session_duration_limit;

        if (my $until = $self_exclusion->exclude_until) {
            $until = Date::Utility->new($until);
            if (Date::Utility::today->days_between($until) < 0) {
                $get_self_exclusion->{exclude_until} = $until->date;
            }
        }

        if (my $timeout_until = $self_exclusion->timeout_until) {
            $timeout_until = Date::Utility->new($timeout_until);
            if ($timeout_until->is_after(Date::Utility->new)) {
                $get_self_exclusion->{timeout_until} = $timeout_until->epoch;
            }
        }
    }

    return $get_self_exclusion;
}

rpc set_self_exclusion => sub {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my $lim = $client->get_self_exclusion_until_date;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'SelfExclusion',
            message_to_client => localize(
                'Sorry, but you have self-excluded yourself from the website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact the Customer Support team for assistance.',
                $lim
            ),
        }) if $lim;

    # get old from above sub _get_self_exclusion_details
    my $self_exclusion = _get_self_exclusion_details($client);

    ## validate
    my $error_sub = sub {
        my ($error, $field) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => $error,
            message           => '',
            details           => $field
        });
    };

    my %args = %{$params->{args}};

    my $decimals = Format::Util::Numbers::get_precision_config()->{price}->{$client->currency};
    foreach my $field (qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover/) {
        if ($args{$field} and $args{$field} !~ /^\d{0,20}(?:\.\d{0,$decimals})?$/) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InputValidationFailed',
                    message_to_client => localize("Input validation failed: $field"),
                    details           => {
                        $field => "Please input a valid number.",
                    },
                });
        }
    }

    # at least one setting should present in request
    my $args_count = 0;
    foreach my $field (
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit exclude_until timeout_until/
        )
    {
        $args_count++ if defined $args{$field};
    }
    return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => localize('Please provide at least one self-exclusion setting.')}) unless $args_count;

    foreach my $field (
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit/
        )
    {
        # Client input
        my $val = $args{$field};

        # The minimum is 1 in case of open bets (1 for other cases)
        my $min = $field eq 'max_open_bets' ? 1 : 0;

        # Validate the client input
        my $is_valid = 0;

        # Max balance and Max open bets are given default values, if not set by client
        if ($field eq 'max_balance') {
            $self_exclusion->{$field} //= $client->get_limit_for_account_balance;
        } elsif ($field eq 'max_open_bets') {
            $self_exclusion->{$field} //= $client->get_limit_for_open_positions;
        }

        if ($val and $val > 0) {
            $is_valid = 1;
            if ($self_exclusion->{$field} and $val > $self_exclusion->{$field}) {
                $is_valid = 0;
            }
        }

        next if $is_valid;

        if (defined $val and $self_exclusion->{$field}) {
            return $error_sub->(localize('Please enter a number between [_1] and [_2].', $min, $self_exclusion->{$field}), $field);
        } else {
            delete $args{$field};
        }

    }

    if (my $session_duration_limit = $args{session_duration_limit}) {
        if ($session_duration_limit > 1440 * 42) {
            return $error_sub->(localize('Session duration limit cannot be more than 6 weeks.'), 'session_duration_limit');
        }
    }

    my $exclude_until = $args{exclude_until};
    if (defined $exclude_until && $exclude_until =~ /^\d{4}\-\d{2}\-\d{2}$/) {
        my $now = Date::Utility->new;
        my $six_month =
            Date::Utility->new(DateTime->now()->add(months => 6)->ymd);
        my ($exclusion_end, $exclusion_end_error);
        try {
            $exclusion_end = Date::Utility->new($exclude_until);
        }
        catch {
            $exclusion_end_error = 1;
        };
        return $error_sub->(localize('Exclusion time conversion error.'), 'exclude_until') if $exclusion_end_error;

        # checking for the exclude until date which must be larger than today's date
        if (not $exclusion_end->is_after($now)) {
            return $error_sub->(localize('Exclude time must be after today.'), 'exclude_until');
        }

        # checking for the exclude until date could not be less than 6 months
        elsif ($exclusion_end->epoch < $six_month->epoch) {
            return $error_sub->(localize('Exclude time cannot be less than 6 months.'), 'exclude_until');
        }

        # checking for the exclude until date could not be more than 5 years
        elsif ($exclusion_end->days_between($now) > 365 * 5 + 1) {
            return $error_sub->(localize('Exclude time cannot be for more than five years.'), 'exclude_until');
        }
    } else {
        delete $args{exclude_until};
    }

    my $timeout_until = $args{timeout_until};
    if (defined $timeout_until and $timeout_until =~ /^\d+$/) {
        my $now           = Date::Utility->new;
        my $exclusion_end = Date::Utility->new($timeout_until);
        my $six_week      = Date::Utility->new(time() + 6 * 7 * 86400);

        # checking for the timeout until which must be larger than current time
        if ($exclusion_end->is_before($now)) {
            return $error_sub->(localize('Timeout time must be greater than current time.'), 'timeout_until');
        }

        if ($exclusion_end->is_after($six_week)) {
            return $error_sub->(localize('Timeout time cannot be more than 6 weeks.'), 'timeout_until');
        }
    } else {
        delete $args{timeout_until};
    }

    if ($args{max_open_bets}) {
        $client->set_exclusion->max_open_bets($args{max_open_bets});
    }

    if ($args{max_balance}) {
        $client->set_exclusion->max_balance($args{max_balance});
    }

    if ($args{max_turnover}) {
        $client->set_exclusion->max_turnover($args{max_turnover});
    }
    if ($args{max_losses}) {
        $client->set_exclusion->max_losses($args{max_losses});
    }
    if ($args{max_7day_turnover}) {
        $client->set_exclusion->max_7day_turnover($args{max_7day_turnover});
    }
    if ($args{max_7day_losses}) {
        $client->set_exclusion->max_7day_losses($args{max_7day_losses});
    }
    if ($args{max_30day_turnover}) {
        $client->set_exclusion->max_30day_turnover($args{max_30day_turnover});
        if ($client->residence eq 'gb') {    # RTS 12 - Financial Limits - UK Clients
            $client->clr_status('ukrts_max_turnover_limit_not_set');
            $client->save;
        }
    }
    if ($args{max_30day_losses}) {
        $client->set_exclusion->max_30day_losses($args{max_30day_losses});
    }

    if ($args{session_duration_limit}) {
        $client->set_exclusion->session_duration_limit($args{session_duration_limit});
    }
    if ($args{timeout_until}) {
        $client->set_exclusion->timeout_until($args{timeout_until});
    }
# send to support only when client has self excluded
    if ($args{exclude_until}) {
        my $ret          = $client->set_exclusion->exclude_until($args{exclude_until});
        my $statuses     = join '/', map { uc $_->status_code } $client->client_status;
        my $name         = ($client->first_name ? $client->first_name . ' ' : '') . $client->last_name;
        my $client_title = join ', ', $client->loginid, $client->email, ($name || '?'), ($statuses ? "current status: [$statuses]" : '');

        my $brand = Brands->new(name => request()->brand);

        my $message = "Client $client_title set the following self-exclusion limits:\n\n- Exclude from website until: $ret\n";

        my $to_email = $brand->emails('compliance') . ',' . $brand->emails('marketing');

        # Include accounts team if client's brokercode is MLT/MX
        # As per UKGC LCCP Audit Regulations
        $to_email .= ',' . $brand->emails('accounting') if ($client->landing_company->short =~ /iom|malta$/);

        send_email({
            from    => $brand->emails('compliance'),
            to      => $to_email,
            subject => "Client " . $client->loginid . " set self-exclusion limits",
            message => [$message],
        });
    }

    $client->save();

    return {status => 1};
};

rpc api_token => sub {
    my $params = shift;

    my ($client, $args, $client_ip) = @{$params}{qw/client args client_ip/};

    my $m = BOM::Database::Model::AccessToken->new;
    my $rtn;
    if ($args->{delete_token}) {
        $m->remove_by_token($args->{delete_token}, $client->loginid);
        $rtn->{delete_token} = 1;
        # send notification to cancel streaming, if we add more streaming
        # for authenticated calls in future, we need to add here as well
        if (defined $params->{account_id}) {
            BOM::Platform::RedisReplicated::redis_write()->publish(
                'TXNUPDATE::transaction_' . $params->{account_id},
                Encode::encode_utf8(
                    $json->encode({
                            error => {
                                code       => "TokenDeleted",
                                account_id => $params->{account_id}}})));
        }
    }
    if (my $display_name = $args->{new_token}) {
        my $display_name_err;
        if ($display_name =~ /^[\w\s\-]{2,32}$/) {
            if ($m->is_name_taken($client->loginid, $display_name)) {
                $display_name_err = localize('The name is taken.');
            }
        } else {
            $display_name_err = localize('alphanumeric with space and dash, 2-32 characters');
        }
        unless ($display_name_err) {
            my $token_cnt = $m->get_token_count_by_loginid($client->loginid);
            $display_name_err = localize('Max 30 tokens are allowed.') if $token_cnt >= 30;
        }
        if ($display_name_err) {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'APITokenError',
                message_to_client => $display_name_err,
            });
        }
        ## for old API calls (we'll make it required on v4)
        my $scopes = $args->{new_token_scopes} || ['read', 'trade', 'payments', 'admin'];
        if ($args->{valid_for_current_ip_only}) {
            $m->create_token($client->loginid, $display_name, $scopes, $client_ip);
        } else {
            $m->create_token($client->loginid, $display_name, $scopes);
        }
        $rtn->{new_token} = 1;
    }

    $rtn->{tokens} = $m->get_tokens_by_loginid($client->loginid);

    return $rtn;
};

rpc tnc_approval => sub {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    if ($params->{args}->{ukgc_funds_protection}) {
        $client->set_status('ukgc_funds_protection', 'system', 'Client acknowledges the protection level of funds');
        if (not $client->save()) {
            return BOM::RPC::v3::Utility::client_error();
        }
    } else {
        my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
        my $client_tnc_status   = $client->get_status('tnc_approval');

        if (not $client_tnc_status
            or ($client_tnc_status->reason ne $current_tnc_version))
        {
            $client->set_status('tnc_approval', 'system', $current_tnc_version);
            if (not $client->save()) {
                return BOM::RPC::v3::Utility::client_error();
            }
        }
    }

    return {status => 1};
};

rpc login_history => sub {
    my $params = shift;

    my $client = $params->{client};

    my $limit = 10;
    if (exists $params->{args}->{limit}) {
        if ($params->{args}->{limit} > 50) {
            $limit = 50;
        } else {
            $limit = $params->{args}->{limit};
        }
    }

    my $user = BOM::User->new({email => $client->email});
    my $login_history = $user->find_login_history(
        sort_by => 'history_date desc',
        limit   => $limit
    );

    my @history = ();
    foreach my $record (@{$login_history}) {
        push @history,
            {
            time        => Date::Utility->new($record->history_date)->epoch,
            action      => $record->action,
            status      => $record->successful ? 1 : 0,
            environment => $record->environment
            };
    }

    return {records => [@history]};
};

rpc set_account_currency => sub {
    my $params = shift;

    my ($client, $currency) = @{$params}{qw/client currency/};

    # Get suspended currencies
    my %suspended_currencies = map { $_ => 1 } split /,/, BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocurrencies;

    # Return an error if the currency is a suspended currency or if the currency chosen is not a legal currency
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidCurrency',
            message_to_client => localize("The provided currency [_1] is not applicable for this account.", $currency)})
        if (not $client->landing_company->is_currency_legal($currency)
        or exists $suspended_currencies{$currency});

    # bail out if default account is already set
    return {status => 0} if $client->default_account;

    # check if we are allowed to set currency
    # i.e if we have exhausted available options
    # - client can have single fiat currency
    # - client can have multiple crypto currency
    #   but only with single type of crypto currency
    #   for example BTC => ETH is allowed but BTC => BTC is not
    if (not $client->is_virtual) {
        my $error = BOM::RPC::v3::Utility::validate_set_currency($client, $currency);
        return $error if $error;
    }

    # bail out if default account is already set
    return {status => 0} if $client->default_account;

    # no change in default account currency if default account is already set
    return {status => 1} if ($client->set_default_account($currency));

    return {status => 0};
};

rpc set_financial_assessment => sub {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return BOM::RPC::v3::Utility::permission_error() if ($client->is_virtual or $client->landing_company->short eq 'japan');

    my ($response, $subject, $message);
    try {
        my %financial_data = map { $_ => $params->{args}->{$_} } (keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});
        my $financial_evaluation = BOM::Platform::Account::Real::default::get_financial_assessment_score(\%financial_data);

        my $user = BOM::User->new({email => $client->email});
        foreach my $cli ($user->clients) {
            $cli->financial_assessment({
                data => Encode::encode_utf8($json->encode($financial_evaluation->{user_data})),
            });
            $cli->save;
        }

        $response = {
            score => $financial_evaluation->{total_score},
        };
        $subject = $client_loginid . ' assessment test details have been updated';
        $message = ["$client_loginid score is " . $financial_evaluation->{total_score}];
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'UpdateAssessmentError',
                message_to_client => localize("Sorry, an error occurred while processing your request.")});
        $subject = "$client_loginid - assessment test details error";
        $message = ["An error occurred while updating assessment test details for $client_loginid. Please handle accordingly."];
    };

    my $brand = Brands->new(name => request()->brand);
    #only send email for MF-client
    send_email({
            from    => $brand->emails('support'),
            to      => $brand->emails('compliance'),
            subject => $subject,
            message => $message,
        }) if $client->landing_company->short eq 'maltainvest';

    return $response;
};

rpc get_financial_assessment => sub {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if ($client->is_virtual or $client->landing_company->short eq 'japan');

    my $response             = {};
    my $financial_assessment = $client->financial_assessment();
    if ($financial_assessment) {
        my $data = $json->decode($financial_assessment->data);
        if ($data) {
            foreach my $key (keys %$data) {
                unless ($key =~ /total_score/) {
                    $response->{$key} = $data->{$key}->{answer};
                }
            }
            $response->{score} = $data->{total_score};
        }
    }

    return $response;
};

rpc reality_check => sub {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')}
            ),
            ;
    }

    my $client        = $params->{client};
    my $token_details = $params->{token_details};

    my $has_reality_check = $client->landing_company->has_reality_check;
    return {} unless ($has_reality_check);

    # we get token creation time and as cap limit if creation time is less than 48 hours from current
    # time we default it to 48 hours, default 48 hours was decided To limit our definition of session
    # if you change this please ask compliance first
    my $start = $token_details->{epoch};
    my $tm    = time - 48 * 3600;
    $start = $tm unless $start and $start > $tm;

    # sell expired contracts so that reality check has proper
    # count for open_contract_count
    BOM::Transaction::sell_expired_contracts({
        client => $client,
        source => $params->{source},
    });

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $client->loginid,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    my $data = $txn_dm->get_reality_check_data_of_account(Date::Utility->new($start)) // {};
    if ($data and scalar @$data) {
        $data = $data->[0];
    } else {
        $data = {};
    }

    my $summary = {
        loginid    => $client->loginid,
        start_time => $start
    };

    foreach (("buy_count", "buy_amount", "sell_count", "sell_amount")) {
        $summary->{$_} = $data->{$_} // 0;
    }
    $summary->{currency}            = $data->{currency_code} // '';
    $summary->{potential_profit}    = $data->{pot_profit}    // 0;
    $summary->{open_contract_count} = $data->{open_cnt}      // 0;

    return $summary;
};

1;

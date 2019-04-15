package BOM::RPC::v3::Accounts;

=head1 BOM::RPC::v3::Accounts

This package contains methods for Account entities in our system.

=cut

use 5.014;
use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Try::Tiny;
use WWW::OneAll;
use Date::Utility;
use HTML::Entities qw(encode_entities);
use List::Util qw(any sum0 first);
use Digest::SHA qw(hmac_sha256_hex);

use Brands;
use BOM::User::Client;
use BOM::User::FinancialAssessment qw(is_section_complete update_financial_assessment decode_fa build_financial_assessment);
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use ExchangeRates::CurrencyConverter qw(in_usd);

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode);
use BOM::RPC::v3::PortfolioManagement;
use BOM::Transaction::History qw(get_transaction_history);
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Client::CashierValidation;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale qw/get_state_by_id/;
use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Token;
use BOM::Transaction;
use BOM::MT5::User::Async;
use BOM::Config;
use BOM::User::Password;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Model::AccessToken;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::Model::OAuth;
use BOM::Database::Model::UserConnect;
use BOM::Config::Runtime;
use BOM::Config::ContractPricingLimits qw(market_pricing_limits);

use constant DEFAULT_STATEMENT_LIMIT => 100;

my $allowed_fields_for_virtual = qr/set_settings|email_consent|residence|allow_copiers/;
my $email_field_labels         = {
    exclude_until          => 'Exclude from website until',
    max_balance            => 'Maximum account cash balance',
    max_turnover           => 'Daily turnover limit',
    max_losses             => 'Daily limit on losses',
    max_7day_turnover      => '7-day turnover limit',
    max_7day_losses        => '7-day limit on losses',
    max_30day_turnover     => '30-day turnover limit',
    max_30day_losses       => '30-day limit on losses',
    max_open_bets          => 'Maximum number of open positions',
    session_duration_limit => 'Session duration limit, in minutes',
    timeout_until          => 'Time out until'
};

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

    foreach my $type ('gaming_company', 'financial_company') {
        if (($landing_company{$type} // '') ne 'none') {
            $landing_company{$type} = __build_landing_company($registry->get($landing_company{$type}));
        } else {
            delete $landing_company{$type};
        }
    }

    # mt5 structure as per country config
    # 'mt' => {
    #    'gaming' => {
    #         'standard' => 'none'
    #    },
    #    'financial' => {
    #         'advanced' => 'none',
    #         'standard' => 'none'
    #    }
    # }

    # need to send it like
    # {
    #   mt_gaming_company: {
    #    standard: {}
    #   },
    #   mt_financial_company: {
    #    advanced: {},
    #    standard: {}
    #   }
    # }

    # we don't want to send "mt" as key so need to delete from structure
    my $mt5_landing_company_details = delete $landing_company{mt};

    foreach my $mt5_type (keys %{$mt5_landing_company_details}) {
        foreach my $mt5_sub_type (keys %{$mt5_landing_company_details->{$mt5_type}}) {
            next
                unless exists $mt5_landing_company_details->{$mt5_type}{$mt5_sub_type}
                and $mt5_landing_company_details->{$mt5_type}{$mt5_sub_type} ne 'none';

            $landing_company{"mt_${mt5_type}_company"}{$mt5_sub_type} =
                __build_landing_company($registry->get($mt5_landing_company_details->{$mt5_type}{$mt5_sub_type}));
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
    my $lc = shift;

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
        has_reality_check                 => $lc->has_reality_check ? 1 : 0,
        currency_config                   => market_pricing_limits($payout_currencies, $lc->short, $lc->legal_allowed_markets),
        requirements                      => $lc->requirements,
        changeable_fields                 => $lc->changeable_fields,
    };
}

rpc statement => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')});
    }

    my $client = $params->{client};
    BOM::RPC::v3::PortfolioManagement::_sell_expired_contracts($client, $params->{source});

    $params->{args}->{limit} //= DEFAULT_STATEMENT_LIMIT;

    my $transaction_res = get_transaction_history($params);
    return {
        transactions => [],
        count        => 0
    } unless (keys %$transaction_res);

    my $currency_code = $client->default_account->currency_code();
    # combine all trades, and sort by transaction_id
    my @transactions = reverse sort { 0 + $a->{transaction_id} <=> 0 + $b->{transaction_id} }
        (@{$transaction_res->{open_trade}}, @{$transaction_res->{close_trade}}, @{$transaction_res->{payment}});

    my @short_codes = map { $_->{short_code} || () } @transactions;
    my $longcodes;
    $longcodes = longcode({
            short_codes => \@short_codes,
            currency    => $currency_code,
        }) if scalar @short_codes;

    my @txns;
    for my $txn (@transactions) {

        my $struct = {
            balance_after    => formatnumber('amount', $currency_code, $txn->{balance_after}),
            transaction_id   => $txn->{id},
            reference_id     => $txn->{buy_tr_id},
            contract_id      => $txn->{financial_market_bet_id},
            transaction_time => $txn->{transaction_time},
            action_type      => $txn->{action_type},
            amount           => $txn->{amount},
            payout           => $txn->{payout_price},
        };

        if ($txn->{financial_market_bet_id}) {
            if ($txn->{action_type} eq 'sell') {
                $struct->{purchase_time} = Date::Utility->new($txn->{purchase_time})->epoch;
            }
        }

        if ($params->{args}->{description}) {
            if ($txn->{short_code}) {
                $struct->{longcode} = $longcodes->{longcodes}->{$txn->{short_code}} // localize('Could not retrieve contract details');
            } else {
                # withdrawal/deposit
                $struct->{longcode} = localize($txn->{payment_remark} // '');
            }

            $struct->{shortcode} = $txn->{short_code};
        }

        $struct->{app_id} = BOM::RPC::v3::Utility::mask_app_id($txn->{source}, $txn->{transaction_time});

        push @txns, $struct;
    }

    return {
        transactions => [@txns],
        count        => scalar @txns
    };
};

rpc request_report => sub {
    my $params = shift;

    my $client = $params->{client};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InputValidationFailed',
            message_to_client => localize("From date must be before To date for sending statement")}
    ) unless ($params->{args}->{date_to} > $params->{args}->{date_from});

    # more different type of reports maybe added here in the future

    if ($params->{args}->{report_type} eq 'statement') {

        my $res = BOM::Platform::Event::Emitter::emit(
            'email_statement',
            {
                loginid   => $client->loginid,
                source    => $params->{source},
                date_from => $params->{args}->{date_from},
                date_to   => $params->{args}->{date_to},
            });

        return {report_status => 1} if $res;

    }

    return BOM::RPC::v3::Utility::client_error();
};

rpc account_statistics => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')});
    }

    my $client = $params->{client};
    my $args   = $params->{args};

    my $account = $client->account;
    return {
        total_deposits    => '0.00',
        total_withdrawals => '0.00',
        currency          => '',
    } unless $account;

    my ($total_deposits, $total_withdrawals);
    try {
        ($total_deposits, $total_withdrawals) = $client->db->dbic->run(
            fixup => sub {
                my $sth = $_->prepare("SELECT * FROM betonmarkets.get_total_deposits_and_withdrawals(?)");
                $sth->execute($account->id);
                return @{$sth->fetchrow_arrayref};
            });
    }
    catch {
        warn "Error caught : $_\n";
        return BOM::RPC::v3::Utility::client_error();
    };

    my $currency_code = $account->currency_code();
    $total_deposits    = formatnumber('amount', $currency_code, $total_deposits);
    $total_withdrawals = formatnumber('amount', $currency_code, $total_withdrawals);

    return {
        total_deposits    => $total_deposits,
        total_withdrawals => $total_withdrawals,
        currency          => $currency_code,
    };
};

rpc profit_table => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
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
    $res = longcode({
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
        currency => $client->default_account->currency_code(),
        balance  => formatnumber('amount', $client->default_account->currency_code(), $client->default_account->balance)};
};

rpc get_account_status => sub {
    my $params = shift;

    my $client = $params->{client};

    my $status                     = $client->status->visible;
    my $id_auth_status             = $client->authentication_status;
    my $authentication_in_progress = $id_auth_status =~ /under_review|needs_action/;

    push @$status, 'document_' . $id_auth_status if $authentication_in_progress;

    push @$status, 'authenticated' if ($client->fully_authenticated);

    my $aml_level = $client->aml_risk_level();

    my $user = $client->user;

    # differentiate between social and password based accounts
    push @$status, 'social_signup' if $user->{has_social_signup};

    # check whether the user need to perform financial assessment
    push(@$status, 'financial_information_not_complete')
        unless is_section_complete(decode_fa($client->financial_assessment()), "financial_information");
    push(@$status, 'trading_experience_not_complete')
        unless is_section_complete(decode_fa($client->financial_assessment()), "trading_experience");
    push(@$status, 'financial_assessment_not_complete') unless $client->is_financial_assessment_complete();

    # check if the user's documents are expired or expiring soon
    if ($client->documents_expired()) {
        push(@$status, 'document_expired');
    } elsif ($client->documents_expired(Date::Utility->new()->plus_time_interval('1mo'))) {
        push(@$status, 'document_expiring_soon');
    }

    my $shortcode                     = $client->landing_company->short;
    my $prompt_client_to_authenticate = 0;
    if ($client->fully_authenticated) {
        $prompt_client_to_authenticate = 1 if BOM::Transaction::Validation->new({clients => [$client]})->check_authentication_required($client);
    } elsif ($authentication_in_progress) {
        $prompt_client_to_authenticate = 1;
    } else {
        if ($shortcode eq 'costarica' or $shortcode eq 'champion') {
            # Our threshold is 4000 USD, but we want to include total across all the user's currencies
            my $total = sum0(
                map { in_usd($_->default_account->balance, $_->currency) }
                grep { $_->default_account && $_->landing_company->short eq $shortcode } $user->clients
            );
            if ($total > 4000) {
                $prompt_client_to_authenticate = 1;
            }
        } elsif ($shortcode eq 'virtual') {
            # No authentication for virtual accounts - set this explicitly in case we change the default above
            $prompt_client_to_authenticate = 0;
        } else {
            # Authentication required for all regulated companies - we'll handle this on the frontend
            $prompt_client_to_authenticate = 1;
        }
    }

    return {
        status                        => $status,
        prompt_client_to_authenticate => $prompt_client_to_authenticate,
        risk_classification           => $aml_level
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

    # if the user doesn't exist or
    # has no associated clients then throw exception
    my $user = $client->user;
    my @clients;
    if (not $user or not @clients = $user->clients) {
        return BOM::RPC::v3::Utility::client_error();
    }

    # do not allow social based clients to reset password
    return BOM::RPC::v3::Utility::create_error({
            code              => "SocialBased",
            message_to_client => localize("Sorry, your account does not allow passwords because you use social media to log in.")}
    ) if $user->{has_social_signup};

    if (
        my $pass_error = BOM::RPC::v3::Utility::_check_password({
                old_password => $args->{old_password},
                new_password => $args->{new_password},
                user_pass    => $user->{password}}))
    {
        return $pass_error;
    }

    my $new_password = BOM::User::Password::hashpw($args->{new_password});
    $user->update_password($new_password);

    my $oauth = BOM::Database::Model::OAuth->new;
    for my $obj (@clients) {
        $obj->password($new_password);
        $obj->save;
        $oauth->revoke_tokens_by_loginid($obj->loginid);
    }

    BOM::User::AuditLog::log('password has been changed', $client->email);
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

        my $user = $client->user;
        if (BOM::User::Password::checkpw($lock_password, $user->{password})) {
            return $error_sub->(localize('Please use a different password than your login password.'));
        }

        if (my $pass_error = BOM::RPC::v3::Utility::_check_password({new_password => $lock_password})) {
            return $pass_error;
        }

        $client->cashier_setting_password(BOM::User::Password::hashpw($lock_password));
        if (not $client->save()) {
            return $error_sub->(localize('Sorry, an error occurred while processing your request.'));
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
        if (!BOM::User::Password::checkpw($unlock_password, $cashier_password)) {
            BOM::User::AuditLog::log('Failed attempt to unlock cashier', $client->loginid);
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
            return $error_sub->(localize('Sorry, an error occurred while processing your request.'));
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
            BOM::User::AuditLog::log('cashier unlocked', $client->loginid);
            return {status => 0};
        }
    }
};

rpc "reset_password",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;
    my $args   = $params->{args};
    my $email  = lc(BOM::Platform::Token->new({token => $args->{verification_code}})->email // '');
    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'reset_password')->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    my $user = BOM::User->new(
        email => $email,
    );
    my @clients = ();
    if (not $user or not @clients = $user->clients) {
        return BOM::RPC::v3::Utility::client_error();
    }

    # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
    my $client = $clients[0];

    # we do not want to leak out any internal information so always return status of 1
    # we do not want this call to continue running if user signed up using oneall
    return {status => 1} if $user->{has_social_signup};

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

    my $new_password = BOM::User::Password::hashpw($args->{new_password});
    $user->update_password($new_password);

    my $oauth = BOM::Database::Model::OAuth->new;
    for my $obj (@clients) {
        $obj->password($new_password);
        $obj->save;
        $oauth->revoke_tokens_by_loginid($obj->loginid);
    }

    BOM::User::AuditLog::log('password has been reset', $email, $args->{verification_code});
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

    my $client_tnc_status = $client->status->tnc_approval;
    my $user              = $client->user;

    return {
        email     => $client->email,
        country   => $country,
        residence => $country
        , # Everywhere else in our responses to FE, we pass the residence key instead of country. However, we need to still pass in country for backwards compatibility.
        country_code  => $country_code,
        email_consent => ($user and $user->{email_consent}) ? 1 : 0,
        has_secret_answer => ($client->secret_answer) ? 1 : 0,
        (
              ($user and BOM::Config::third_party()->{elevio}{account_secret})
            ? (user_hash => hmac_sha256_hex($user->email, BOM::Config::third_party()->{elevio}{account_secret}))
            : ()
        ),
        (
            $client->is_virtual ? ()
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
                citizen                        => $client->citizen // '',
                is_authenticated_payment_agent => ($client->payment_agent and $client->payment_agent->is_authenticated) ? 1 : 0,
                client_tnc_status => $client_tnc_status ? $client_tnc_status->{reason} : '',
                place_of_birth    => $client->place_of_birth,
                tax_residence     => $client->tax_residence,
                tax_identification_number   => $client->tax_identification_number,
                account_opening_reason      => $client->account_opening_reason,
                request_professional_status => $client->status->professional_requested ? 1 : 0
            ))};
};

rpc set_settings => sub {
    my $params = shift;

    my $current_client = $params->{client};

    my ($website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/website_name client_ip user_agent language args/};
    $user_agent //= '';

    my $brand = Brands->new(name => request()->brand);
    my ($residence, $allow_copiers) =
        ($args->{residence}, $args->{allow_copiers});

    if ($current_client->is_virtual) {
        # Virtual client can update
        # - residence, if residence not set.
        # - email_consent (common to real account as well)
        if (not $current_client->residence and $residence) {

            if ($brand->countries_instance->restricted_country($residence)) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'InvalidResidence',
                        message_to_client => localize('Sorry, our service is not available for your country of residence.')});
            } else {
                $current_client->residence($residence);
                if (not $current_client->save()) {
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

        for my $detail (qw (secret_answer secret_question)) {
            if ($args->{$detail} && $current_client->$detail) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Already have a [_1].", $detail)});
            }
        }

        if ($args->{secret_answer} xor $args->{secret_question}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize("Need both secret question and secret answer.")});
        }

        if ($args->{account_opening_reason}) {
            if ($current_client->landing_company->is_field_changeable_before_auth('account_opening_reason')) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of account opening reason cannot be changed after authentication.")})
                    if ($current_client->account_opening_reason
                    and $args->{account_opening_reason} ne $current_client->account_opening_reason
                    and $current_client->fully_authenticated());
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow account opening reason to be changed.")})
                    if ($current_client->account_opening_reason
                    and $args->{account_opening_reason} ne $current_client->account_opening_reason);
            }
        }

        if ($args->{place_of_birth}) {

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InputValidationFailed',
                    message_to_client => localize("Please enter a valid place of birth.")}
            ) unless Locale::Country::code2country($args->{place_of_birth});

            if ($current_client->landing_company->is_field_changeable_before_auth('place_of_birth')) {

                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of place of birth cannot be changed after authentication.")})
                    if ($current_client->place_of_birth
                    and $args->{place_of_birth} ne $current_client->place_of_birth
                    and $current_client->fully_authenticated());
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow place of birth to be changed.")})
                    if ($current_client->place_of_birth
                    and $args->{place_of_birth} ne $current_client->place_of_birth);
            }
        }

        if ($args->{date_of_birth}) {
            $args->{date_of_birth} = BOM::Platform::Account::Real::default::format_date($args->{date_of_birth});

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidDateOfBirth',
                    message_to_client => localize("Date of birth is invalid.")}) unless $args->{date_of_birth};

            if ($current_client->landing_company->is_field_changeable_before_auth('date_of_birth')) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of date of birth cannot be changed after authentication.")})
                    if ($current_client->date_of_birth
                    and $args->{date_of_birth} ne $current_client->date_of_birth
                    and $current_client->fully_authenticated());
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of date of birth is below the minimum age required.")})
                    if ($current_client->date_of_birth
                    and $args->{date_of_birth} ne $current_client->date_of_birth
                    and BOM::Platform::Account::Real::default::validate_dob($args->{date_of_birth}, $current_client->residence));
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow date of birth to be changed.")})
                    if ($current_client->date_of_birth
                    and $args->{date_of_birth} ne $current_client->date_of_birth);
            }
        }

        if ($args->{salutation}) {
            if ($current_client->landing_company->is_field_changeable_before_auth('salutation')) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of salutation cannot be changed after authentication.")})
                    if ($current_client->salutation
                    and $args->{salutation} ne $current_client->salutation
                    and $current_client->fully_authenticated());
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow salutation to be changed.")})
                    if ($current_client->salutation
                    and $args->{salutation} ne $current_client->salutation);
            }
        }

        if ($args->{first_name}) {
            if ($current_client->landing_company->is_field_changeable_before_auth('first_name')) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of first name cannot be changed after authentication.")})
                    if ($current_client->first_name
                    and $args->{first_name} ne $current_client->first_name
                    and $current_client->fully_authenticated());
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow first name to be changed.")})
                    if ($current_client->first_name
                    and $args->{first_name} ne $current_client->first_name);
            }
        }

        if ($args->{last_name}) {
            if ($current_client->landing_company->is_field_changeable_before_auth('last_name')) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Value of last name cannot be changed after authentication.")})
                    if ($current_client->last_name
                    and $args->{last_name} ne $current_client->last_name
                    and $current_client->fully_authenticated());
            } else {
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'PermissionDenied',
                        message_to_client => localize("Your landing company does not allow last name to be changed.")})
                    if ($current_client->last_name
                    and $args->{last_name} ne $current_client->last_name);
            }
        }

        if ($current_client->residence eq 'gb' and defined $args->{address_postcode} and $args->{address_postcode} eq '') {
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
        and ($current_client->landing_company->short ne 'costarica' and not $current_client->is_virtual);

    if (
        $allow_copiers
        and @{BOM::Database::DataMapper::Copier->new(
                broker_code => $current_client->broker_code,
                operation   => 'replica'
                )->get_traders({copier_id => $current_client->loginid})
                || []})
    {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AllowCopiersError',
                message_to_client => localize("Copier can't be a trader.")});
    }

    my $user = $current_client->user;

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined $args->{email_consent}) {
        $user->update_email_fields(email_consent => $args->{email_consent});

        BOM::Platform::Event::Emitter::emit(
            'email_consent',
            {
                loginid       => $current_client->loginid,
                email_consent => $args->{email_consent}});
    }

    # only allow current client to set allow_copiers
    if (defined $allow_copiers) {
        $current_client->allow_copiers($allow_copiers);
        return BOM::RPC::v3::Utility::client_error() unless $current_client->save();
    }

    return {status => 1} if $current_client->is_virtual;

    my $tax_residence             = $args->{'tax_residence'}             // '';
    my $tax_identification_number = $args->{'tax_identification_number'} // '';

    # according to compliance, tax_residence and tax_identification_number can be changed
    # but cannot be removed once they have been set
    foreach my $field (qw(tax_residence tax_identification_number)) {
        if ($current_client->$field and exists $args->{$field} and not $args->{$field}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize('Tax information cannot be removed once it has been set.'),
                    details           => {
                        field => $field,
                    },
                });
        }
    }

    # This can be a comma-separated list - if that's the case, we'll just use the first failing residence in
    # the error message.
    if (my $bad_residence = first { $brand->countries_instance->restricted_country($_) } split /,/, $tax_residence || '') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'RestrictedCountry',
                message_to_client => localize('The supplied tax residence "[_1]" is in a restricted country.', uc $bad_residence)});
    }
    return BOM::RPC::v3::Utility::create_error({
            code => 'TINDetailsMandatory',
            message_to_client =>
                localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')}
    ) if ($current_client->landing_company->short eq 'maltainvest' and (not $tax_residence or not $tax_identification_number));

    if ($args->{citizen}) {
        if ($current_client->landing_company->is_field_changeable_before_auth('citizen')) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize("Value of citizen cannot be changed after authentication.")})
                if ($current_client->citizen
                and $args->{citizen} ne $current_client->citizen
                and $current_client->fully_authenticated());
        } else {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize("Your landing company does not allow citizen to be changed.")})
                if ($current_client->citizen
                and $args->{citizen} ne $current_client->citizen);
        }
    }

    my $now                    = Date::Utility->new;
    my $address1               = $args->{'address_line_1'} // $current_client->address_1;
    my $address2               = ($args->{'address_line_2'} // $current_client->address_2) // '';
    my $addressTown            = $args->{'address_city'} // $current_client->city;
    my $addressState           = ($args->{'address_state'} // $current_client->state) // '';
    my $addressPostcode        = $args->{'address_postcode'} // $current_client->postcode;
    my $phone                  = ($args->{'phone'} // $current_client->phone) // '';
    my $birth_place            = $args->{place_of_birth} // $current_client->place_of_birth;
    my $date_of_birth          = $args->{date_of_birth} // $current_client->date_of_birth;
    my $citizen                = ($args->{'citizen'} // $current_client->citizen) // '';
    my $salutation             = $args->{'salutation'} // $current_client->salutation;
    my $first_name             = $args->{'first_name'} // $current_client->first_name;
    my $last_name              = $args->{'last_name'} // $current_client->last_name;
    my $account_opening_reason = $args->{'account_opening_reason'} // $current_client->account_opening_reason;
    my $secret_answer          = $args->{secret_answer} ? BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) : '';
    my $secret_question        = $args->{secret_question} // '';

    my $dup_details = {
        first_name    => $first_name,
        last_name     => $last_name,
        date_of_birth => $date_of_birth,
        email         => $current_client->email,
    };
    $dup_details->{phone} = $phone if $phone ne $current_client->phone;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Sorry, an account already exists with those details. Only one real money account is allowed per client.')})

        if (($args->{first_name} and $args->{first_name} ne $current_client->first_name)
        or ($args->{last_name} and $args->{last_name} ne $current_client->last_name)
        or $dup_details->{phone}
        or ($args->{date_of_birth} and $args->{date_of_birth} ne $current_client->date_of_birth))

        and BOM::Database::ClientDB->new({broker_code => $current_client->broker_code})->get_duplicate_client($dup_details);

    my $cil_message;
    #citizenship is mandatory for some clients,so we shouldnt let them to remove it
    return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Citizenship is required.')}

    ) if ((any { $_ eq "citizen" } $current_client->landing_company->requirements->{signup}->@*) && !$citizen);
    if ($args->{'citizen'}
        && !defined $brand->countries_instance->countries->country_from_code($args->{'citizen'}))
    {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidCitizen',
                message_to_client => localize('Sorry, our service is not available for your country of citizenship.')});
    }

    if ((
               ($address1 and $address1 ne $current_client->address_1)
            or ($address2 ne $current_client->address_2)
            or ($addressTown ne $current_client->city)
            or ($addressState ne $current_client->state)
            or ($addressPostcode ne $current_client->postcode))
        and $current_client->fully_authenticated
        )
    {
        $cil_message =
              'Authenticated client ['
            . $current_client->loginid
            . '] updated his/her address from ['
            . join(' ',
            $current_client->address_1,
            $current_client->address_2,
            $current_client->city, $current_client->state, $current_client->postcode)
            . '] to ['
            . join(' ', $address1, $address2, $addressTown, $addressState, $addressPostcode) . ']';
    }

    # only allowed to set for maltainvest, costarica and only
    # if professional status is not set or requested
    my $update_professional_status = sub {
        my ($client_obj) = @_;
        if (    $args->{request_professional_status}
            and $client_obj->landing_company->short =~ /^(?:costarica|maltainvest)$/
            and not($client_obj->status->professional or $client_obj->status->professional_requested))
        {
            $client_obj->status->multi_set_clear({
                set        => ['professional_requested'],
                clear      => ['professional_rejected'],
                staff_name => 'SYSTEM',
                reason     => 'Professional account requested'
            });

            return 1;
        }
        return undef;
    };

    my @realclient_loginids = $user->bom_real_loginids;

    foreach my $loginid (@realclient_loginids) {
        my $client = $loginid eq $current_client->loginid ? $current_client : BOM::User::Client->new({loginid => $loginid});

        $client->address_1($address1);
        $client->address_2($address2);
        $client->city($addressTown);
        $client->state($addressState) if defined $addressState;                       # FIXME validate
        $client->postcode($addressPostcode) if defined $args->{'address_postcode'};
        $client->phone($phone);
        $client->citizen($citizen);
        $client->place_of_birth($birth_place);
        $client->account_opening_reason($account_opening_reason);
        $client->date_of_birth($date_of_birth);
        $client->salutation($salutation);
        $client->first_name($first_name);
        $client->last_name($last_name);
        $client->secret_answer($secret_answer)     if $secret_answer;
        $client->secret_question($secret_question) if $secret_question;

        $client->latest_environment($now->datetime . ' ' . $client_ip . ' ' . $user_agent . ' LANG=' . $language);

        # As per CRS/FATCA regulatory requirement we need to
        # save this information as client status, so updating
        # tax residence and tax number will create client status
        # as we have database trigger for that now
        if ((
                   $tax_residence
                or $tax_identification_number
            )
            and (  ($client->tax_residence // '') ne $tax_residence
                or ($client->tax_identification_number // '') ne $tax_identification_number))
        {
            $client->tax_residence($tax_residence)                         if $tax_residence;
            $client->tax_identification_number($tax_identification_number) if $tax_identification_number;
        }

        my $set_status = $update_professional_status->($client);

        if (not $client->save()) {
            return BOM::RPC::v3::Utility::client_error();
        }

        BOM::RPC::v3::Utility::send_professional_requested_email($client->loginid, $client->residence, $client->landing_company->short)
            if ($set_status);
    }

    if ($cil_message) {
        $current_client->add_note('Update Address Notification', $cil_message);
    }

    my $message = localize(
        'Dear [_1] [_2] [_3],',
        map { encode_entities($_) } BOM::Platform::Locale::translate_salutation($current_client->salutation),
        $current_client->first_name,
        $current_client->last_name
    ) . "\n\n";
    $message .= localize('Please note that your settings have been updated as follows:') . "\n\n";

    # lookup state name by id
    my $lookup_state =
        ($current_client->state and $current_client->residence)
        ? BOM::Platform::Locale::get_state_by_id($current_client->state, $current_client->residence) // ''
        : '';
    my @address_fields = ((map { $current_client->$_ } qw/address_1 address_2 city/), $lookup_state, $current_client->postcode);
    # filter out empty fields
    my $full_address = join ', ', grep { defined $_ and /\S/ } @address_fields;

    my $residence_country = Locale::Country::code2country($current_client->residence);
    my @updated_fields    = (
        [localize('Email address'),        $current_client->email],
        [localize('Country of Residence'), $residence_country],
        [localize('Address'),              $full_address],
        [localize('Telephone'),            $current_client->phone],
        [localize('Citizen'),              $current_client->citizen]);

    my $tr_tax_residence = join ', ', map { Locale::Country::code2country($_) } split /,/, ($current_client->tax_residence || '');
    my $pob_country = $current_client->place_of_birth ? Locale::Country::code2country($current_client->place_of_birth) : '';

    push @updated_fields,
        (
        [localize('Place of birth'), $pob_country // ''],
        [localize("Tax residence"), $tr_tax_residence],
        [localize('Tax identification number'), ($current_client->tax_identification_number || '')],
        );
    push @updated_fields, [localize('Receive news and special offers'), $current_client->user->{email_consent} ? localize("Yes") : localize("No")]
        if exists $args->{email_consent};
    push @updated_fields, [localize('Allow copiers'), $current_client->allow_copiers ? localize("Yes") : localize("No")]
        if defined $allow_copiers;
    push @updated_fields,
        [
        localize('Requested professional status'),
        (
                   $args->{request_professional_status}
                or $current_client->status->professional_requested
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
        from                  => $brand->emails('support'),
        to                    => $current_client->email,
        subject               => $current_client->loginid . ' ' . localize('Change in account settings'),
        message               => [$message],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => $current_client->loginid,
    });
    BOM::User::AuditLog::log('Your settings have been updated successfully', $current_client->loginid);
    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $current_client->loginid});

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
            if (Date::Utility::today()->days_between($until) < 0) {
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
                    message_to_client => localize("Input validation failed: [_1].", $field),
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
        my $now       = Date::Utility->new;
        my $six_month = Date::Utility->new->plus_time_interval('6mo');
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
            $client->status->clear_ukrts_max_turnover_limit_not_set;
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
    if ($args{exclude_until}) {
        $client->set_exclusion->exclude_until($args{exclude_until});
    }
# Need to send email in 2 circumstances:
#   - Any client sets a self exclusion period
#   - Client under Binary (Europe) Limited with MT5 account(s) sets any of these settings
    my @mt5_logins = $client->user->mt5_logins('real');

    if ($client->landing_company->short eq 'malta' && @mt5_logins) {
        warn 'Compliance email regarding Binary (Europe) Limited user with MT5 account(s) failed to send.'
            unless send_self_exclusion_notification($client, 'malta_with_mt5', \%args);
    } elsif ($args{exclude_until}) {
        warn 'Compliance email regarding self exclusion from the website failed to send.'
            unless send_self_exclusion_notification($client, 'self_exclusion', \%args);
    }

    $client->save();

    return {status => 1};
};

sub send_self_exclusion_notification {
    my ($client, $type, $args) = @_;

    my @fields_to_email;
    my $message;
    if ($type eq 'malta_with_mt5') {
        $message = "An MT5 account holder under the Binary (Europe) Limited landing company has set account limits.\n";
        @fields_to_email =
            qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit exclude_until timeout_until/;
    } elsif ($type eq 'self_exclusion') {
        $message         = "A user has excluded themselves from the website.\n";
        @fields_to_email = qw/exclude_until/;
    }

    if (@fields_to_email) {
        my $name = ($client->first_name ? $client->first_name . ' ' : '') . $client->last_name;
        my $statuses = join '/', map { uc $_ } @{$client->status->all};
        my $client_title = join ', ', $client->loginid, $client->email, ($name || '?'), ($statuses ? "current status: [$statuses]" : '');

        my $brand = Brands->new(name => request()->brand);

        $message .= "Client $client_title set the following self-exclusion limits:\n\n";

        foreach (@fields_to_email) {
            my $label = $email_field_labels->{$_};
            my $val   = $args->{$_};
            $message .= "$label: $val\n" if $val;
        }

        my @mt5_logins = $client->user->mt5_logins('real');
        if ($type eq 'malta_with_mt5' && @mt5_logins) {
            $message .= "\n\nClient $client_title has the following MT5 accounts:\n";
            $message .= "$_\n" for @mt5_logins;
        }

        my $to_email = $brand->emails('compliance') . ',' . $brand->emails('marketing');

        # Include accounts team if client's brokercode is MLT/MX
        # As per UKGC LCCP Audit Regulations
        $to_email .= ',' . $brand->emails('accounting') if ($client->landing_company->short =~ /iom|malta$/);

        return send_email({
            from    => $brand->emails('compliance'),
            to      => $to_email,
            subject => "Client " . $client->loginid . " set self-exclusion limits",
            message => [$message],
        });
    }
    return 0;
}

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
            BOM::Config::RedisReplicated::redis_write()->publish(
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
    my $error;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    if ($params->{args}->{ukgc_funds_protection}) {
        if (not eval { $client->status->set('ukgc_funds_protection', 'system', 'Client acknowledges the protection level of funds'); }) {
            return BOM::RPC::v3::Utility::client_error();
        }
    } else {
        my $current_tnc_version = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version;
        my $client_tnc_status   = $client->status->tnc_approval;

        if (not $client_tnc_status
            or ($client_tnc_status->{reason} ne $current_tnc_version))
        {
            try { $client->status->set('tnc_approval', 'system', $current_tnc_version) } catch { $error = BOM::RPC::v3::Utility::client_error() };
            return $error if $error;
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

    my $user          = $client->user;
    my $login_history = $user->login_history(
        order => 'desc',
        limit => $limit
    );

    my @history = ();
    foreach my $record (@{$login_history}) {
        push @history,
            {
            time        => Date::Utility->new($record->{history_date})->epoch,
            action      => $record->{action},
            status      => $record->{successful} ? 1 : 0,
            environment => $record->{environment}};
    }

    return {records => [@history]};
};

rpc account_closure => sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};

    my $closing_reason = $args->{reason};

    my $user = $client->user;
    my @accounts_to_disable = $user->clients(include_disabled => 0);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'ReasonNotSpecified',
            message_to_client => localize('Please specify the reasons for closing your accounts.')}) if $closing_reason =~ /^\s*$/;

    # This for-loop is for balance validation and open positions checking
    # No account is to be disabled if there is at least one real-account with balance
    foreach my $client (@accounts_to_disable) {
        next if ($client->is_virtual || !$client->account);

        return BOM::RPC::v3::Utility::create_error({
                code => 'AccountHasOpenPositions',
                message_to_client =>
                    localize('There are open positions in your accounts. Please make sure all positions are closed before proceeding.')}
        ) if @{$client->get_open_contracts};

        return BOM::RPC::v3::Utility::create_error({
                code              => 'RealAccountHasBalance',
                message_to_client => localize('Your accounts still have funds. Please withdraw all funds before proceeding.')}
        ) if $client->account->balance > 0;
    }

    foreach my $mt5_loginid ($user->get_mt5_loginids) {
        $mt5_loginid =~ s/\D//g;
        my $mt5_user = BOM::MT5::User::Async::get_user($mt5_loginid)->get;
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5AccountHasBalance',
                message_to_client => localize('Your MT5 accounts still have funds. Please withdraw all funds before proceeding.')}
        ) if (($mt5_user->{group} =~ /^real/) && ($mt5_user->{balance} > 0));
    }

    # This for-loop is for disabling the accounts
    # If an error occurs, it will be emailed to CS to disable manually
    my $loginids_disabled_success = '';
    my $loginids_disabled_failed  = '';

    my $loginid = $client->loginid;
    my $error;

    foreach my $client (@accounts_to_disable) {
        try {
            $client->status->set('disabled', $loginid, $closing_reason);
            $loginids_disabled_success .= $client->loginid . ' ';
        }
        catch {
            $error = BOM::RPC::v3::Utility::client_error();
            $loginids_disabled_failed .= $client->loginid . ' ';
        };
    }

    # Return error if NO loginids have been disabled
    return $error if ($error && $loginids_disabled_success eq '');

    my $data_closure = {
        closing_reason    => $closing_reason,
        loginid           => $loginid,
        loginids_disabled => $loginids_disabled_success,
        loginids_failed   => $loginids_disabled_failed
    };

    my $data_email_consent = {
        loginid       => $loginid,
        email_consent => 0
    };

    # Remove email consents for the user (and update the clients as well)
    $user->update_email_fields(email_consent => $data_email_consent->{email_consent});
    BOM::Platform::Event::Emitter::emit('email_consent', $data_email_consent);

    BOM::Platform::Event::Emitter::emit('account_closure', $data_closure);

    return {status => 1};
};

rpc set_account_currency => sub {
    my $params = shift;

    my ($client, $currency) = @{$params}{qw/client currency/};

    # check if we are allowed to set currency
    # i.e if we have exhausted available options
    # - client can have single fiat currency
    # - client can have multiple crypto currency
    #   but only with single type of crypto currency
    #   for example BTC => ETH is allowed but BTC => BTC is not
    # - currency is not legal in the landing company
    # - currency is crypto and crytocurrency is suspended in system config

    my $error = BOM::RPC::v3::Utility::validate_set_currency($client, $currency);
    return $error if $error;

    my $status  = 0;
    my $account = $client->account;

    try {
        if ($account && $account->currency_code() ne $currency) {
            # Change currency
            $status = 1 if $account->currency_code($currency) eq $currency;
        } else {
            # Initial set of currency
            $status = 1 if $client->account($currency);
        }
    }
    catch {
        warn "Error caught in set_account_currency: $_\n";
    };
    return {status => $status};
};

rpc set_financial_assessment => sub {
    my $params         = shift;
    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    return BOM::RPC::v3::Utility::permission_error() if ($client->is_virtual);

    my $is_FI_complete = is_section_complete($params->{args}, "financial_information");
    my $is_TE_complete = is_section_complete($params->{args}, "trading_experience");

    return BOM::RPC::v3::Utility::create_error({
            code              => 'IncompleteFinancialAssessment',
            message_to_client => localize("The financial assessment is not complete")}
    ) unless ($client->landing_company->short eq "maltainvest" ? $is_TE_complete && $is_FI_complete : $is_FI_complete);

    update_financial_assessment($client->user, $params->{args});

    # This is here to continue sending scores through our api as we cannot change the output of our calls. However, this should be removed with v4 as this is not used by front-end at all
    my $response = build_financial_assessment($params->{args})->{scores};

    $response->{financial_information_score} = delete $response->{financial_information};
    $response->{trading_score}               = delete $response->{trading_experience};

    return $response;
};

rpc get_financial_assessment => sub {
    my $params = shift;

    my $client = $params->{client};
    return BOM::RPC::v3::Utility::permission_error() if ($client->is_virtual);

    my $response = decode_fa($client->financial_assessment());

    # This is here to continue sending scores through our api as we cannot change the output of our calls. However, this should be removed with v4 as this is not used by front-end at all
    if (keys %$response) {
        my $scores = build_financial_assessment($response)->{scores};

        $scores->{financial_information_score} = delete $scores->{financial_information};
        $scores->{trading_score}               = delete $scores->{trading_experience};

        $response = {%$response, %$scores};
    }

    return $response;
};

rpc reality_check => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
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

rpc copytrading_list => sub {
    my $params = shift;

    my $current_client = $params->{client};

    my $copiers_data_mapper = BOM::Database::DataMapper::Copier->new({
        broker_code => $current_client->broker_code,
        operation   => 'replica'
    });

    my $copiers = $copiers_data_mapper->get_copiers_tokens_all({trader_id => $current_client->loginid});
    my @copiers = map { {loginid=>$_->[0]} } @$copiers;
    my $traders = $copiers_data_mapper->get_traders_all({copier_id => $current_client->loginid});

    return {
        copiers => \@copiers,
        traders => $traders
    };
};

1;

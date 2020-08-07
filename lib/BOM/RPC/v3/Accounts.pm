package BOM::RPC::v3::Accounts;

=head1 BOM::RPC::v3::Accounts

This package contains methods for Account entities in our system.

=cut

use 5.014;
use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Syntax::Keyword::Try;
use WWW::OneAll;
use Date::Utility;
use List::Util qw(any sum0 first min uniq);
use Digest::SHA qw(hmac_sha256_hex);
use Text::Trim qw(trim);

use BOM::User::Client;
use BOM::User::FinancialAssessment qw(is_section_complete update_financial_assessment decode_fa build_financial_assessment);
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode log_exception);
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
use BOM::Platform::Token::API;
use BOM::Transaction;
use BOM::MT5::User::Async;
use BOM::Config;
use BOM::User::Password;
use BOM::User::Phone;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::Platform::Token::API;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::Model::OAuth;
use BOM::Database::Model::UserConnect;
use BOM::Config::Runtime;
use BOM::Config::Quants qw(market_pricing_limits);
use BOM::RPC::v3::Services;
use BOM::Config::Redis;
use BOM::User::Onfido;

use constant DEFAULT_STATEMENT_LIMIT              => 100;
use constant ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX => 'ONFIDO::ALLOW_RESUBMISSION::ID::';
use constant POA_ALLOW_RESUBMISSION_KEY_PREFIX    => 'POA::ALLOW_RESUBMISSION::ID::';

use constant DOCUMENT_EXPIRING_SOON_INTERVAL => '1mo';

my $allowed_fields_for_virtual = qr/set_settings|email_consent|residence|allow_copiers|non_pep_declaration/;
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

our %ImmutableFieldError = do {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        place_of_birth            => localize("Your place of birth cannot be changed."),
        date_of_birth             => localize("Your date of birth cannot be changed."),
        salutation                => localize("Your salutation cannot be changed."),
        first_name                => localize("Your first name cannot be changed."),
        last_name                 => localize("Your last name cannot be changed."),
        citizen                   => localize("Your citizen cannot be changed."),
        account_opening_reason    => localize("Your account opening reason cannot be changed."),
        secret_answer             => localize("Your secret answer cannot be changed."),
        secret_question           => localize("Your secret question cannot be changed."),
        tax_residence             => localize("Your tax residence cannot be changed."),
        tax_identification_number => localize("Your tax identification number cannot be changed."),
    );
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
    my $lc = $client ? $client->landing_company : LandingCompany::Registry::get($params->{landing_company_name} || 'svg');

    # ... but we fall back to `svg` as a useful default, since it has most
    # currencies enabled.

    # Remove cryptocurrencies that have been suspended
    return BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);
    };

rpc "landing_company",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $country  = $params->{args}->{landing_company};
    my $configs  = request()->brand->countries_instance->countries_list;
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
    #         'financial' => 'none'
    #    },
    #    'financial' => {
    #         'financial_stp' => 'none',
    #         'financial' => 'none'
    #    }
    # }

    # need to send it like
    # {
    #   mt_gaming_company: {
    #    financial: {}
    #   },
    #   mt_financial_company: {
    #    financial_stp: {},
    #    financial: {}
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

rpc "statement",
    category => 'account',
    sub {
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
        (@{$transaction_res->{open_trade}}, @{$transaction_res->{close_trade}}, @{$transaction_res->{payment}}, @{$transaction_res->{escrow}});

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
            } elsif ($txn->{payment_id}) {
                # withdrawal/deposit
                $struct->{longcode} = localize($txn->{payment_remark} // '');
            } else {
                $struct->{longcode} = localize($txn->{remark} // '');
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
        warn "Error caught : $@\n";
        log_exception();
        return BOM::RPC::v3::Utility::client_error();
    }

    my $currency_code = $account->currency_code();
    $total_deposits    = formatnumber('amount', $currency_code, $total_deposits);
    $total_withdrawals = formatnumber('amount', $currency_code, $total_withdrawals);

    return {
        total_deposits    => $total_deposits,
        total_withdrawals => $total_withdrawals,
        currency          => $currency_code,
    };
};

rpc "profit_table",
    category => 'account',
    sub {
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

    Returns balance for one or all accounts.
    An oauth token is required for all accounts.

=cut

rpc balance => sub {
    my $params = shift;
    my $arg_account = $params->{args}{account} // 'current';

    my @user_logins = $params->{client}->user->bom_loginids;

    my $loginid = ($arg_account eq 'current' or $arg_account eq 'all') ? $params->{client}->loginid : $arg_account;
    unless (any { $loginid eq $_ } @user_logins) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $client = $loginid eq $params->{client}->loginid ? $params->{client} : BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });

    my $response = {loginid => $client->loginid};

    if ($client->default_account) {
        $response->{currency}   = $client->default_account->currency_code();
        $response->{balance}    = formatnumber('amount', $client->default_account->currency_code(), $client->default_account->balance);
        $response->{account_id} = $client->default_account->id;
    } else {
        $response->{currency}   = '';
        $response->{balance}    = '0.00';
        $response->{account_id} = '';
    }

    return $response unless ($arg_account eq 'all');

    # now is all accounts - need OAuth token
    unless (($params->{token_type} // '') eq 'oauth_token') {
        return BOM::RPC::v3::Utility::create_error({
                code              => "PermissionDenied",
                message_to_client => localize('Permission denied, balances of all accounts require oauth token')});
    }

    #if (client has real account with USD OR doesn’t have fiat account) {
    #    use ‘USD’;
    #} elsif (there is more than one fiat account) {
    #    use currency of financial account (MF or CR);
    #} else {
    #    use currency of fiat account;
    #}
    my ($has_usd, $financial_currency, $fiat_currency);
    my $clients = $params->{client}->user->accounts_by_category(\@user_logins);

    for my $sibling ($clients->{enabled}->@*) {
        next unless $sibling->account;
        my $currency = $sibling->account->currency_code;
        next unless LandingCompany::Registry::get_currency_type($currency) eq 'fiat';
        $has_usd            = 1         if $currency eq 'USD';
        $financial_currency = $currency if $sibling->loginid =~ /^(MF|CR)/;
        $fiat_currency      = $currency;
    }

    my $total_currency;
    if ($has_usd || !$fiat_currency) {
        $total_currency = 'USD';
    } elsif ($financial_currency) {
        $total_currency = $financial_currency;
    } else {
        $total_currency = $fiat_currency;
    }

    my $real_total = 0;
    my $demo_total = 0;

    for my $sibling ($clients->{enabled}->@*, $clients->{virtual}->@*) {

        unless ($sibling->account) {
            $response->{accounts}{$sibling->loginid} = {
                currency         => '',
                balance          => '0.00',
                converted_amount => '0.00',
                account_id       => '',
                demo_account     => $sibling->is_virtual ? 1 : 0,
                type             => 'deriv',
            };
            next;
        }

        my $converted = convert_currency($sibling->account->balance, $sibling->account->currency_code, $total_currency);
        $real_total += $converted unless $sibling->is_virtual;
        $demo_total += $converted if $sibling->is_virtual;

        $response->{accounts}{$sibling->loginid} = {
            currency         => $sibling->account->currency_code,
            balance          => formatnumber('amount', $sibling->account->currency_code, $sibling->account->balance),
            converted_amount => formatnumber('amount', $total_currency, $converted),
            account_id       => $sibling->account->id,
            demo_account     => $sibling->is_virtual ? 1 : 0,
            type             => 'deriv',
            currency_rate_in_total_currency =>
                convert_currency(1, $sibling->account->currency_code, $total_currency),    # This rate is used for the future stream
        };
    }

    my $mt5_real_total = 0;
    my $mt5_demo_total = 0;

    my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($params->{client})->get;

    for my $mt5_account (@mt5_accounts) {
        my $is_demo = $mt5_account->{group} =~ /^demo/ ? 1 : 0;
        my $converted = convert_currency($mt5_account->{balance}, $mt5_account->{currency}, $total_currency);
        $mt5_real_total += $converted unless $is_demo;
        $mt5_demo_total += $converted if $is_demo;

        $response->{accounts}{$mt5_account->{login}} = {
            currency         => $mt5_account->{currency},
            balance          => formatnumber('amount', $mt5_account->{currency}, $mt5_account->{balance}),
            converted_amount => formatnumber('amount', $total_currency, $converted),
            demo_account     => $is_demo,
            type             => 'mt5',
            currency_rate_in_total_currency =>
                convert_currency(1, $mt5_account->{currency}, $total_currency),    # This rate is used for the future stream
        };

    }

    $response->{total} = {
        deriv => {
            amount   => formatnumber('amount', $total_currency, $real_total),
            currency => $total_currency,
        },
        deriv_demo => {
            amount   => formatnumber('amount', $total_currency, $demo_total),
            currency => $total_currency,
        },
        mt5 => {
            amount   => formatnumber('amount', $total_currency, $mt5_real_total),
            currency => $total_currency,
        },
        mt5_demo => {
            amount   => formatnumber('amount', $total_currency, $mt5_demo_total),
            currency => $total_currency,
        },
    };

    return $response;
};

rpc get_account_status => sub {
    my $params = shift;

    my $client = $params->{client};

    my $status                     = $client->status->visible;
    my $id_auth_status             = $client->authentication_status;
    my $authentication_in_progress = $id_auth_status =~ /under_review|needs_action/;

    push @$status, 'document_' . $id_auth_status if $authentication_in_progress;

    if ($client->fully_authenticated()) {
        push @$status, 'authenticated';
        # we send this status as client is already authenticated
        # so they can view upload more documents if needed
        push @$status, 'allow_document_upload';
    } elsif ($client->landing_company->is_authentication_mandatory
        or ($client->aml_risk_classification // '') eq 'high'
        or $client->status->withdrawal_locked
        or $client->status->allow_document_upload)
    {
        push @$status, 'allow_document_upload';
    }

    my $user = $client->user;

    # differentiate between social and password based accounts
    push @$status, 'social_signup' if $user->{has_social_signup};

    # check whether the user need to perform financial assessment
    my $client_fa = decode_fa($client->financial_assessment());

    push(@$status, 'financial_information_not_complete') unless is_section_complete($client_fa, "financial_information");

    push(@$status, 'trading_experience_not_complete') unless is_section_complete($client_fa, "trading_experience");

    push(@$status, 'financial_assessment_not_complete') unless $client->is_financial_assessment_complete();

    my $is_document_expiry_check_required = $client->is_document_expiry_check_required_mt5();
    if ($is_document_expiry_check_required) {
        # check if the user's documents are expired or expiring soon
        if ($client->documents_expired()) {
            push(@$status, 'document_expired');
        } elsif ($client->is_any_document_expiring_by_date(Date::Utility->new()->plus_time_interval(DOCUMENT_EXPIRING_SOON_INTERVAL))) {
            push(@$status, 'document_expiring_soon');
        }
    }

    my %currency_config = map {
        $_ => {
            is_deposit_suspended    => BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $_),
            is_withdrawal_suspended => BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $_),
            }
    } $client->currency;

    return {
        status                        => $status,
        risk_classification           => $client->risk_level(),
        prompt_client_to_authenticate => $client->is_verification_required(check_authentication_status => 1),
        authentication                => _get_authentication(
            client                            => $client,
            is_document_expiry_check_required => $is_document_expiry_check_required
        ),
        currency_config => \%currency_config,
    };
};

=begin comment

  {
    # this will act as flag on which part of authentication
    # flow to show, if its empty it means we don't need to prompt client
    "needs_verification": ["identity", "document"],
    # these individual sections are for information purpose only
    # if needs_verification is non-empty then these should be validated
    # to represent or request details from client accordingly
    "identity": {
      "status": "verified", # [none, pending, rejected, verified, expired]
      "expiry_date": 12423423
    },
    "document":{
      "status": "rejected", # [none, pending, rejected, verified, expired]
      "expiry_date": 12423423
    }
  }

=end comment
=cut

sub _get_authentication {
    my %args = @_;

    my $client                            = $args{client};
    my $is_document_expiry_check_required = $args{is_document_expiry_check_required};

    my $authentication_object = {
        needs_verification => [],
        identity           => {
            status                        => "none",
            further_resubmissions_allowed => 0,
            services                      => {
                onfido => {
                    is_country_supported => 0,
                    documents_supported  => []}}
        },
        document => {
            status                        => "none",
            further_resubmissions_allowed => 0,
        },
    };

    return $authentication_object if $client->is_virtual;

    my $redis = BOM::Config::Redis::redis_replicated_write();
    $authentication_object->{identity}{further_resubmissions_allowed} =
        $redis->get(ONFIDO_ALLOW_RESUBMISSION_KEY_PREFIX . $client->binary_user_id) // 0;

    $authentication_object->{document}{further_resubmissions_allowed} =
        $redis->get(POA_ALLOW_RESUBMISSION_KEY_PREFIX . $client->binary_user_id) // 0;

    my $country_code = uc($client->place_of_birth // '');
    $authentication_object->{identity}{services}{onfido}{is_country_supported} = BOM::Config::Onfido::is_country_supported($country_code);
    $authentication_object->{identity}{services}{onfido}{documents_supported} =
        BOM::Config::Onfido::supported_documents_for_country($country_code);

    my $documents = $client->documents_uploaded();

    my ($poi_documents, $poi_minimum_expiry_date, $is_poi_already_expired, $is_poi_pending) =
        @{$documents->{proof_of_identity}}{qw/documents minimum_expiry_date is_expired is_pending/};
    my ($poa_documents, $poa_minimum_expiry_date, $is_poa_already_expired, $is_poa_pending, $is_rejected) =
        @{$documents->{proof_of_address}}{qw/documents minimum_expiry_date is_expired is_pending is_rejected/};

    my %needs_verification_hash = ();

    my $poi_structure = sub {
        $authentication_object->{identity}{expiry_date} = $poi_minimum_expiry_date if $poi_minimum_expiry_date and $is_document_expiry_check_required;

        $authentication_object->{identity}{status} = 'pending' if $is_poi_pending;
        # check for expiry
        if ($is_poi_already_expired and $is_document_expiry_check_required) {
            $authentication_object->{identity}{status} = 'expired';
            $needs_verification_hash{identity} = 'identity';
        }

        return undef;
    };

    my $poa_structure = sub {
        $authentication_object->{document}{expiry_date} = $poa_minimum_expiry_date if $poa_minimum_expiry_date and $is_document_expiry_check_required;

        # check for expiry
        if ($is_poa_already_expired and $is_document_expiry_check_required) {
            $authentication_object->{document}{status} = 'expired';
            $needs_verification_hash{document} = 'document';
        }

        $authentication_object->{document}{status} = 'pending' if $is_poa_pending;
        if ($is_rejected) {
            $authentication_object->{document}{status} = 'rejected';
            $needs_verification_hash{document} = 'document';
        }

        return undef;
    };

    # fully authenticated
    return do {
        $authentication_object->{identity}{status} = 'verified';
        $authentication_object->{document}{status} = 'verified';

        $poi_structure->();
        $poa_structure->();

        $authentication_object->{needs_verification} = [sort keys %needs_verification_hash];

        $authentication_object;
    } if $client->fully_authenticated();

    # variable for caching result
    my ($is_verification_required, $is_verification_required_check_authentication_status);

    # proof of identity provided
    return do {
        # proof of identity
        $authentication_object->{identity}{status} = "verified";
        $poi_structure->();

        # proof of address
        if (not $poa_documents) {
            $is_verification_required_check_authentication_status //= $client->is_verification_required(check_authentication_status => 1);
            $needs_verification_hash{document} = 'document' if $is_verification_required_check_authentication_status;
        } else {
            $poa_structure->();
        }

        $authentication_object->{needs_verification} = [sort keys %needs_verification_hash];
        $authentication_object;
    } if $client->status->age_verification;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my $user_applicant = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM users.get_onfido_applicant(?::BIGINT)', undef, $client->binary_user_id);
        });
    # if documents are there and we have onfido applicant then
    # check for onfido check status and inform accordingly
    if ($user_applicant) {

        my $user_check = BOM::User::Onfido::get_latest_onfido_check($client->binary_user_id);

        unless ($user_check) {
            $is_verification_required //= $client->is_verification_required();
            $needs_verification_hash{identity} = 'identity' if $is_verification_required;
        } else {
            if (my $check_id = $user_check->{id}) {
                if ($user_check->{status} =~ /^in_progress|awaiting_applicant$/) {
                    $authentication_object->{identity}->{status} = 'pending';
                } elsif ($user_check->{result} eq 'consider') {
                    my $user_reports = BOM::User::Onfido::get_all_onfido_reports($client->binary_user_id, $check_id);

                    # check for document result as we have accepted documents
                    # manually so facial similarity is not accurate as client
                    # use to provide selfie while holding identity card
                    my $report_document = first { ($_->{api_name} // '') eq 'document' }
                    sort { Date::Utility->new($a->{created_at})->is_before(Date::Utility->new($b->{created_at})) ? 1 : 0 } values %$user_reports;

                    my $report_document_sub_result = $report_document->{sub_result} // '';
                    $needs_verification_hash{identity} = 1 if $report_document_sub_result =~ /^rejected|suspected|caution/;
                    $authentication_object->{identity}->{status} = $report_document_sub_result
                        if $report_document_sub_result =~ /^rejected|suspected/;
                    $authentication_object->{identity}->{status} = 'rejected' if $report_document_sub_result eq 'caution';
                    $authentication_object->{identity}->{status} = 'pending'
                        if (($report_document_sub_result =~ /^clear|consider/) and not $client->status->age_verification);
                }
            }
        }
    } elsif (not $poi_documents) {
        $is_verification_required //= $client->is_verification_required();
        $needs_verification_hash{identity} = 'identity' if $is_verification_required;
    } else {
        $poi_structure->();
    }

    $is_verification_required_check_authentication_status //= $client->is_verification_required(check_authentication_status => 1);

    # proof of address
    if (not $poa_documents) {
        $needs_verification_hash{document} = 'document' if $is_verification_required_check_authentication_status;
    } else {
        $poa_structure->();
    }

    # If needs action and not age verified, we require both POI and POA
    if ($is_verification_required_check_authentication_status and not defined $client->status->age_verification) {
        $needs_verification_hash{identity} = 'identity' if $authentication_object->{identity}->{status} eq 'none';
    }

    $authentication_object->{needs_verification} = [sort keys %needs_verification_hash];
    return $authentication_object;
}

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

    my $email = $client->email;
    BOM::User::AuditLog::log('password has been changed', $email);
    send_email({
        to                 => $client->email,
        subject            => localize('Your password has been changed.'),
        template_name      => 'reset_password_confirm',
        template_args      => {email => $email},
        use_email_template => 1,
        template_loginid   => $client->loginid,
        use_event          => 1,
    });

    return {status => 1};
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

    unless ($client->is_virtual) {
        if ($args->{date_of_birth}) {

            (my $user_dob = $args->{date_of_birth}) =~ s/-0/-/g;
            (my $db_dob   = $client->date_of_birth) =~ s/-0/-/g;

            return BOM::RPC::v3::Utility::create_error({
                    code              => "DateOfBirthMismatch",
                    message_to_client => localize("The email address and date of birth do not match.")}) if ($user_dob ne $db_dob);
        }
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

    # if user have social signup and decided to proceed, update has_social_signup to false
    if ($user->{has_social_signup}) {
        # remove social signup flag
        $user->update_has_social_signup(0);
        #remove all other social accounts
        my $user_connect = BOM::Database::Model::UserConnect->new;
        my @providers    = $user_connect->get_connects_by_user_id($user->{id});
        $user_connect->remove_connect($user->{id}, $_) for @providers;
    }

    BOM::User::AuditLog::log('password has been reset', $email, $args->{verification_code});
    send_email({
        to                 => $email,
        subject            => localize('Your password has been reset.'),
        template_name      => 'reset_password_confirm',
        template_args      => {email => $email},
        use_email_template => 1,
        template_loginid   => $client->loginid,
        use_event          => 1,
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
        $country = request()->brand->countries_instance->countries->localized_code2country($client->residence, $params->{language});
    }

    my $user = $client->user;

    my $settings = {
        email     => $user->email,
        country   => $country,
        residence => $country
        , # Everywhere else in our responses to FE, we pass the residence key instead of country. However, we need to still pass in country for backwards compatibility.
        country_code  => $country_code,
        email_consent => ($user and $user->{email_consent}) ? 1 : 0,
        (
              ($user and BOM::Config::third_party()->{elevio}{account_secret})
            ? (user_hash => hmac_sha256_hex($user->email, BOM::Config::third_party()->{elevio}{account_secret}))
            : ())};

    my @clients = grep { not $_->is_virtual } $user->clients(include_disabled => 0);
    my ($real_client) = sort { $b->date_joined cmp $a->date_joined } @clients;

    if ($real_client) {
        # We should pick the information from the first created account for
        # account settings attributes/fields that sync between clients - personal information
        # And, use current client to return account settings attributes/fields
        # for others, like is_authenticated_payment_agent, since they account specific
        $settings = {
            %$settings,
            has_secret_answer => defined $real_client->secret_answer ? 1 : 0,
            salutation        => $real_client->salutation,
            first_name        => $real_client->first_name,
            last_name         => $real_client->last_name,
            address_line_1    => $real_client->address_1,
            address_line_2    => $real_client->address_2,
            address_city      => $real_client->city,
            address_state     => $real_client->state,
            address_postcode  => $real_client->postcode,
            phone             => $real_client->phone,
            place_of_birth    => $real_client->place_of_birth,
            tax_residence     => $real_client->tax_residence,
            tax_identification_number => $real_client->tax_identification_number,
            account_opening_reason    => $real_client->account_opening_reason,
            date_of_birth             => $real_client->date_of_birth ? Date::Utility->new($real_client->date_of_birth)->epoch : undef,
            citizen       => $real_client->citizen  // '',
            allow_copiers => $client->allow_copiers // 0,
            non_pep_declaration         => $client->non_pep_declaration_time       ? 1                                       : 0,
            client_tnc_status           => $client->status->tnc_approval           ? $client->status->tnc_approval->{reason} : '',
            request_professional_status => $client->status->professional_requested ? 1                                       : 0,
            is_authenticated_payment_agent => ($client->payment_agent and $client->payment_agent->is_authenticated) ? 1 : 0,
        };
    }
    return $settings;
};

rpc set_settings => sub {
    my $params = shift;

    my $current_client = $params->{client};
    my $error_map      = BOM::RPC::v3::Utility::error_map();

    my ($website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/website_name client_ip user_agent language args/};
    $user_agent //= '';

    # This function used to find the fields updated to send them as properties to track event
    # TODO Please rename this to updated_fields once you refactor this function to remove deriv set settings email.
    my $updated_fields_for_track = _find_updated_fields($params);

    my $countries_instance = request()->brand->countries_instance();
    my ($residence, $allow_copiers) =
        ($args->{residence}, $args->{allow_copiers});
    my $tax_residence             = $args->{'tax_residence'}             // '';
    my $tax_identification_number = $args->{'tax_identification_number'} // '';

    if ($current_client->is_virtual) {
        # Virtual client can update
        # - residence, if residence not set.
        # - email_consent (common to real account as well)
        if (not $current_client->residence and $residence) {

            if ($countries_instance->restricted_country($residence)) {
                return BOM::RPC::v3::Utility::create_error_by_code('InvalidResidence');
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

        my $error = $current_client->format_input_details($args);
        return BOM::RPC::v3::Utility::create_error_by_code($error->{error}) if $error;
        # This can be a comma-separated list - if that's the case, we'll just use the first failing residence in
        # the error message.
        if (my $bad_residence = first { $countries_instance->restricted_country($_) } split /,/, $tax_residence || '') {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'RestrictedCountry',
                    message_to_client => localize('The supplied tax residence "[_1]" is in a restricted country.', $bad_residence)});
        }
        $error = $current_client->validate_fields_immutable($args);
        if ($error) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize($ImmutableFieldError{$error->{details}})});
        }

        $error = $current_client->validate_common_account_details($args) || $current_client->check_duplicate_account($args);

        if ($error) {
            my $override_code = 'PermissionDenied';
            #not sure if the $override_code = 'InputValidationFailed' is necessary , just safer to keep the return code as before
            $override_code = 'InputValidationFailed' if $error->{error} eq 'InvalidPlaceOfBirth';
            return BOM::RPC::v3::Utility::create_error_by_code($error->{error}, override_code => $override_code);
        }

    }

    return BOM::RPC::v3::Utility::permission_error()
        if $allow_copiers
        and ($current_client->landing_company->short ne 'svg' and not $current_client->is_virtual);

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

    # only allow current client to set allow_copiers
    if (defined $allow_copiers) {
        $current_client->allow_copiers($allow_copiers);
        return BOM::RPC::v3::Utility::client_error() unless $current_client->save();
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

    return {status => 1} if $current_client->is_virtual;

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

    return BOM::RPC::v3::Utility::create_error({
            code => 'TINDetailsMandatory',
            message_to_client =>
                localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')}
    ) if ($current_client->landing_company->short eq 'maltainvest' and (not $tax_residence or not $tax_identification_number));

    # Shold not allow client to change TIN number if we have TIN format for the country and it doesnt match
    # In case of having more than a tax residence, client residence will replaced.
    my $selected_tax_residence = $tax_residence =~ /\,/g ? $current_client->residence : $tax_residence;
    if ($selected_tax_residence and $tax_identification_number and (my $tin_format = $countries_instance->get_tin_format($selected_tax_residence))) {
        my $client_tin = $countries_instance->clean_tin_format($tax_identification_number, $selected_tax_residence) // '';
        stats_inc('bom_rpc.v_3.set_settings.called_with_wrong_TIN_format.count') unless any { $client_tin =~ m/$_/ } @$tin_format;
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
    my $first_name             = trim($args->{'first_name'} // $current_client->first_name);
    my $last_name              = trim($args->{'last_name'} // $current_client->last_name);
    my $account_opening_reason = $args->{'account_opening_reason'} // $current_client->account_opening_reason;
    my $secret_answer          = $args->{secret_answer} ? BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) : '';
    my $secret_question        = $args->{secret_question} // '';

    #citizenship is mandatory for some clients,so we shouldnt let them to remove it
    return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Citizenship is required.')}
    ) if ((any { $_ eq "citizen" } $current_client->landing_company->requirements->{signup}->@*) && !$citizen);

    my ($needs_verify_address_trigger, $cil_message);
    if (   ($address1 and $address1 ne $current_client->address_1)
        or ($address2 ne $current_client->address_2)
        or ($addressTown ne $current_client->city)
        or ($addressState ne $current_client->state)
        or ($addressPostcode ne $current_client->postcode))
    {

        $needs_verify_address_trigger = 1;

        if ($current_client->fully_authenticated()) {
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
    }
    my @realclient_loginids = $user->bom_real_loginids;

    # set professional status for applicable countries
    if ($args->{request_professional_status}) {
        if ($current_client->landing_company->support_professional_client) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize("You already requested professional status.")}
            ) if ($current_client->status->professional or $current_client->status->professional_requested);
            $current_client->status->multi_set_clear({
                set        => ['professional_requested'],
                clear      => ['professional_rejected'],
                staff_name => 'SYSTEM',
                reason     => 'Professional account requested'
            });
            BOM::RPC::v3::Utility::send_professional_requested_email(
                $current_client->loginid,
                $current_client->residence,
                $current_client->landing_company->short
            );
        } else {
            # Return error if there is no applicable client because of landing company restriction
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'PermissionDenied',
                    message_to_client => localize("Professional status is not applicable to your account.")});
        }
    }

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

        # non-pep declaration is shared among siblings of the same landing complany.
        if (   $args->{non_pep_declaration}
            && !$client->non_pep_declaration_time
            && $client->landing_company->short eq $current_client->landing_company->short)
        {
            $client->non_pep_declaration_time(time);
        }

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

        if (not $client->save()) {
            return BOM::RPC::v3::Utility::client_error();
        }
    }
    # When a trader stop being a trader, need to delete from clientdb betonmarkets.copiers
    if (defined $allow_copiers and $allow_copiers == 0) {
        my $copier = BOM::Database::DataMapper::Copier->new(
            broker_code => $current_client->broker_code,
            operation   => 'write'
        );

        if (scalar @{$copier->get_copiers_tokens_all({trader_id => $current_client->loginid}) || []}) {
            $copier->delete_copiers({
                trader_id => $current_client->loginid,
                match_all => 1
            });
        }
    }

    # Send request to update onfido details
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $current_client->loginid});
    BOM::Platform::Event::Emitter::emit('verify_address', {loginid => $current_client->loginid}) if $needs_verify_address_trigger;
    $current_client->add_note('Update Address Notification', $cil_message) if $cil_message;

    # send email only if there was any changes
    if (scalar keys %$updated_fields_for_track) {
        _send_update_account_settings_email($args, $current_client, $updated_fields_for_track, $allow_copiers, $website_name);
        BOM::Platform::Event::Emitter::emit(
            'profile_change',
            {
                loginid    => $current_client->loginid,
                properties => {updated_fields => $updated_fields_for_track}});

        BOM::User::AuditLog::log('Your settings have been updated successfully', $current_client->loginid);
        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $current_client->loginid});
    }

    return {status => 1};
};

rpc get_self_exclusion => sub {
    my $params = shift;

    my $client = $params->{client};
    return _get_self_exclusion_details($client);
};

sub _contains_any {
    my ($hash, @keys) = (@_);
    scalar grep { exists $hash->{$_} } @keys;
}

sub _send_update_account_settings_email {
    my ($args, $current_client, $updated_fields, $allow_copiers, $website_name) = @_;

    # lookup state name by id
    my $lookup_state =
        ($current_client->state and $current_client->residence)
        ? BOM::Platform::Locale::get_state_by_id($current_client->state, $current_client->residence) // ''
        : '';
    my @address_fields = ((map { $current_client->$_ } qw/address_1 address_2 city/), $lookup_state, $current_client->postcode);
    # filter out empty fields
    my $full_address = join ', ', grep { defined $_ and /\S/ } @address_fields;

    my $residence_country    = Locale::Country::code2country($current_client->residence);
    my $citizen_country      = Locale::Country::code2country($current_client->citizen);
    my @email_updated_fields = ([
            localize('Full Name'),
            (
                join ' ',                    BOM::Platform::Locale::translate_salutation($current_client->salutation),
                $current_client->first_name, $current_client->last_name
            ),
            _contains_any($updated_fields, qw{first_name last_name salutation})
        ],
        [localize('Email address'), $current_client->email],
        [
            localize('Date of birth'), Date::Utility->new($current_client->date_of_birth)->date_yyyymmdd,
            _contains_any($updated_fields, 'date_of_birth')
        ],
        [localize('Country of Residence'), $residence_country, _contains_any($updated_fields, 'residence')],
        [
            localize('Address'), $full_address,
            _contains_any($updated_fields, qw{address_city address_line_1 address_line_2 address_postcode address_state})
        ],
        [localize('Telephone'), $current_client->phone, _contains_any($updated_fields, 'phone')],
        [localize('Citizen'),   $citizen_country,       _contains_any($updated_fields, 'citizen')]);

    my $tr_tax_residence = join ', ', map { Locale::Country::code2country($_) } split /,/, ($current_client->tax_residence || '');
    my $pob_country = $current_client->place_of_birth ? Locale::Country::code2country($current_client->place_of_birth) : '';

    push @email_updated_fields,
        (
        [localize('Place of birth'), $pob_country // '', _contains_any($updated_fields, 'place_of_birth')],
        [localize("Tax residence"), $tr_tax_residence, _contains_any($updated_fields, 'tax_residence')],
        [
            localize('Tax identification number'),
            ($current_client->tax_identification_number || ''),
            _contains_any($updated_fields, 'tax_identification_number')
        ],
        [localize('Account opening reason'), $current_client->account_opening_reason, _contains_any($updated_fields, 'account_opening_reason')],
        );
    push @email_updated_fields,
        [
        localize('Receive news and special offers'),
        $current_client->user->{email_consent} ? localize("Yes") : localize("No"),
        _contains_any($updated_fields, 'email_consent')]
        if exists $args->{email_consent};
    push @email_updated_fields,
        [
        localize('Allow copiers'),
        $current_client->allow_copiers ? localize("Yes") : localize("No"),
        _contains_any($updated_fields, 'allow_copiers')]
        if defined $allow_copiers;
    push @email_updated_fields,
        [
        localize('Requested professional status'),
        (
                   $args->{request_professional_status}
                or $current_client->status->professional_requested
            ) ? localize("Yes") : localize("No"),
        _contains_any($updated_fields, 'request_professional_status')];

    send_email({
            to                    => $current_client->email,
            subject               => $current_client->loginid . ' ' . localize('Change in account settings'),
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1,
            template_loginid      => $current_client->loginid,
            template_name         => 'update_account_settings',
            template_args         => {
                updated_fields => [@email_updated_fields],
                salutation     => BOM::Platform::Locale::translate_salutation($current_client->salutation),
                first_name     => $current_client->first_name,
                last_name      => $current_client->last_name,
                website_name   => $website_name,
            },
        });
}

sub _find_updated_fields {
    my $params = shift;
    my ($client, $args) = @{$params}{qw/client args/};
    my $updated_fields;
    my @required_fields =
        qw/account_opening_reason address_city address_line_1 address_line_2 address_postcode address_state allow_copiers citizen date_of_birth first_name last_name phone
        place_of_birth residence salutation secret_answer secret_question tax_identification_number tax_residence/;

    foreach my $field (@required_fields) {
        $updated_fields->{$field} = $args->{$field} if defined($args->{$field}) and $args->{$field} ne ($client->$field // '');
    }
    my $user = $client->user;

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined($args->{email_consent}) and (($user->email_consent // 0) ne $args->{email_consent})) {
        $updated_fields->{email_consent} = $args->{email_consent};
    }

    if (defined $args->{request_professional_status}) {
        if (not $client->status->professional_requested) {
            $updated_fields->{request_professional_status} = 0;
        } else {
            $updated_fields->{request_professional_status} = 1;
        }
    }
    return $updated_fields;
}

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

        if (my $until = $self_exclusion->max_deposit_end_date) {
            $until = Date::Utility->new($until);
            if (Date::Utility::today()->days_between($until) < 0 && $self_exclusion->max_deposit) {
                $get_self_exclusion->{max_deposit}          = $self_exclusion->max_deposit;
                $get_self_exclusion->{max_deposit_end_date} = $until->date;
            }
        }

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
    foreach my $field (qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_deposit/) {
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
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit exclude_until timeout_until max_deposit max_deposit_end_date/
        )
    {
        $args_count++ if defined $args{$field};
    }
    return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => localize('Please provide at least one self-exclusion setting.')}) unless $args_count;

    foreach my $field (
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit max_deposit/
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
            log_exception();
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

    my $max_deposit_end_date = $args{max_deposit_end_date};
    my $max_deposit          = $args{max_deposit};
    if (defined $max_deposit_end_date && defined $max_deposit && $max_deposit_end_date =~ /^\d{4}\-\d{2}\-\d{2}$/) {
        my $now = Date::Utility->new;
        my ($exclusion_end, $exclusion_end_error);
        try {
            $exclusion_end = Date::Utility->new($max_deposit_end_date);
        }
        catch {
            log_exception();
            $exclusion_end_error = 1;
        }
        return $error_sub->(localize('Exclusion time conversion error.'), 'max_deposit_end_date') if $exclusion_end_error;

        # checking for the exclude until date which must be larger than today's date
        if ($exclusion_end->is_before($now)) {
            return $error_sub->(localize('Deposit exclusion period must be after today.'), 'max_deposit_end_date');
        }

        # checking for the deposit exclusion period could not be more than 5 years
        elsif ($exclusion_end->days_between($now) > 365 * 5 + 1) {
            return $error_sub->(localize('Deposit exclusion period cannot be for more than five years.'), 'max_deposit_end_date');
        }
    } else {
        delete $args{max_deposit_end_date};
        delete $args{max_deposit};
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

    if ($max_deposit xor $max_deposit_end_date) {
        return $error_sub->(
            localize('Both [_1] and [_2] must be provided to activate deposit limit.', 'max_deposit', 'max_deposit_end_date'),
            'max_deposit'
        );
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
        if ($client->residence eq 'gb' or $client->landing_company->check_max_turnover_limit_is_set)
        {    # RTS 12 - Financial Limits - UK Clients and MLT clients
            $client->status->clear_max_turnover_limit_not_set;
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
    if ($max_deposit_end_date && $max_deposit) {
        $client->set_exclusion->max_deposit_begin_date(Date::Utility->new->date);
        $client->set_exclusion->max_deposit_end_date($args{max_deposit_end_date});
        $client->set_exclusion->max_deposit($args{max_deposit});
    }

    $args{customerio_suspended} = 0;
    if ($args{exclude_until} && $client->user->email_consent) {

        BOM::Config::Runtime->instance->app_config->check_for_update();
        $args{customerio_suspended} = BOM::Config::Runtime->instance->app_config->system->suspend->customerio;

        my $data_subscription = {
            loginid              => $client->loginid,
            self_excluded        => 1,
            customerio_suspended => $args{customerio_suspended}};
        warn 'emit self_exclude_set  event failed.'
            unless BOM::Platform::Event::Emitter::emit('self_exclude_set', $data_subscription);
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
            qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit exclude_until timeout_until max_deposit max_deposit_end_date/;
    } elsif ($type eq 'self_exclusion') {
        $message         = "A user has excluded themselves from the website.\n";
        @fields_to_email = qw/exclude_until/;
    }

    if (@fields_to_email) {
        my $statuses = join '/', map { uc $_ } @{$client->status->all};
        my $client_title = join ', ', $client->loginid, ($statuses ? "current status: [$statuses]" : '');

        my $brand = request()->brand;

        $message .= "Client $client_title set the following self-exclusion limits:\n\n";

        foreach (@fields_to_email) {
            my $label = $email_field_labels->{$_};
            my $val   = $args->{$_};
            $message .= "$label: $val\n" if $val;
        }
        if ($args->{customerio_suspended}) {
            $message .= "\n\nClient " . $client->loginid . " could not be unsubcribed from cutomerio. Please unsubscribe it manually.\n";
        }

        my @mt5_logins = $client->user->mt5_logins('real');
        if ($type eq 'malta_with_mt5' && @mt5_logins) {
            $message .= "\n\nClient $client_title has the following MT5 accounts:\n";
            $message .= "$_\n" for @mt5_logins;
        }

        my $to_email = $brand->emails('compliance');

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
    my $m = BOM::Platform::Token::API->new;
    my $rtn;
    if (my $token = $args->{delete_token}) {
        my $token_details = $m->get_token_details($token) // {};
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize('No token found'),
            }) unless (($token_details->{loginid} // '') eq $client->loginid);
        # When a token is deleted from authdb, it need to be deleted from clientdb betonmarkets.copiers
        BOM::Database::DataMapper::Copier->new({
                broker_code => $client->broker_code,
                operation   => 'write'
            }
            )->delete_copiers({
                match_all => 1,
                trader_id => $client->loginid,
                token     => $token
            });
        $m->remove_by_token($token, $client->loginid);
        $rtn->{delete_token} = 1;
        # send notification to cancel streaming, if we add more streaming
        # for authenticated calls in future, we need to add here as well
        if (defined $params->{account_id}) {
            BOM::Config::Redis::redis_transaction_write()->publish(
                'TXNUPDATE::transaction_' . $params->{account_id},
                Encode::encode_utf8(
                    $json->encode({
                            error => {
                                code       => "TokenDeleted",
                                token      => $token,
                                account_id => $params->{account_id}}})));
        }
        BOM::Platform::Event::Emitter::emit(
            'api_token_deleted',
            {
                loginid => $client->loginid,
                name    => $token_details->{display_name},
                scopes  => $token_details->{scopes}});
    }
    if (my $display_name = $args->{new_token}) {

        ## for old API calls (we'll make it required on v4)
        my $scopes = $args->{new_token_scopes} || ['read', 'trading_information', 'trade', 'payments', 'admin'];
        my $token = $m->create_token($client->loginid, $display_name, $scopes, ($args->{valid_for_current_ip_only} ? $client_ip : undef));

        if (ref $token eq 'HASH' and my $error = $token->{error}) {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'APITokenError',
                message_to_client => $error,
            });
        }
        $rtn->{new_token} = 1;
        BOM::Platform::Event::Emitter::emit(
            'api_token_created',
            {
                loginid => $client->loginid,
                name    => $display_name,
                scopes  => $scopes
            });
    }

    $rtn->{tokens} = $m->get_tokens_by_loginid($client->loginid);

    return $rtn;
};

async_rpc service_token => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    my @services = ref $args->{service} eq 'ARRAY' ? $args->{service}->@* : ($args->{service});

    my @service_futures;

    for my $service (@services) {

        if ($service eq 'sendbird') {
            try {
                push @service_futures,
                    Future->done({
                        service => $service,
                        $client->p2p_chat_token->%*
                    });
            }
            catch {
                my $err = $@;
                my $err_code = $err->{error_code} // '';

                if (my $message = $BOM::RPC::v3::P2P::ERROR_MAP{$err_code}) {
                    push @service_futures,
                        Future->fail(
                        BOM::RPC::v3::Utility::create_error({
                                code              => $err_code,
                                message_to_client => localize($message),
                            }));
                }
                push @service_futures, Future->fail($@);
            }
        }

        if ($service eq 'onfido') {
            my $referrer = $args->{referrer} // $params->{referrer};
            # The requirement for the format of <referrer> is https://*.<DOMAIN>/*
            # as stated in https://documentation.onfido.com/#generate-web-sdk-token
            $referrer =~ s/(\/\/).*?(\..*?)(\/|$).*/$1\*$2\/\*/g;

            push @service_futures,
                BOM::RPC::v3::Services::service_token(
                $client,
                {
                    service  => $service,
                    referrer => $referrer
                }
                )->then(
                sub {
                    my ($result) = @_;
                    if ($result->{error}) {
                        return Future->fail($result->{error});
                    } else {
                        return Future->done({
                            token   => $result->{token},
                            service => 'onfido',
                        });
                    }
                });
        }
    }

    return Future->needs_all(@service_futures)->then(
        sub {
            my @results = @_;
            return Future->done({map { delete $_->{service} => $_ } @results});
        });

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
            try {
                $client->status->set('tnc_approval', 'system', $current_tnc_version);
            }
            catch {
                log_exception();
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

    my %accounts_with_positions;
    my %accounts_with_balance;
    foreach my $client (@accounts_to_disable) {
        next if ($client->is_virtual || !$client->account);

        my $number_open_contracts = scalar @{$client->get_open_contracts};
        my $balance               = $client->account->balance;

        $accounts_with_positions{$client->loginid} = $number_open_contracts if $number_open_contracts;
        $accounts_with_balance{$client->loginid} = {
            balance  => $balance,
            currency => $client->currency
        } if $balance > 0;
    }

    my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($params->{client})->get;
    foreach my $mt5_account (@mt5_accounts) {
        next if $mt5_account->{group} =~ /^demo/;

        if ($mt5_account->{balance} > 0) {
            $accounts_with_balance{$mt5_account->{login}} = {
                balance  => formatnumber('amount', $mt5_account->{currency}, $mt5_account->{balance}),
                currency => $mt5_account->{currency},
            };
        }

        my $number_open_position = BOM::MT5::User::Async::get_open_positions_count($mt5_account->{login})->get;
        if ($number_open_position && $number_open_position->{total}) {
            $accounts_with_positions{$mt5_account->{login}} = $number_open_position->{total};
        }
    }

    if (%accounts_with_positions || %accounts_with_balance) {
        my @accounts_to_fix = uniq(keys %accounts_with_balance, keys %accounts_with_positions);
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AccountHasBalanceOrOpenPositions',
                message_to_client => localize(
                    'Please close open positions and withdraw all funds from your [_1] account(s) before proceeding.',
                    join(', ', @accounts_to_fix)
                ),
                details => +{
                    %accounts_with_balance   ? (balance        => \%accounts_with_balance)   : (),
                    %accounts_with_positions ? (open_positions => \%accounts_with_positions) : (),
                }});
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
            $client->status->set('closed',   $loginid, $closing_reason);
            $loginids_disabled_success .= $client->loginid . ' ';
        }
        catch {
            log_exception();
            $error = BOM::RPC::v3::Utility::client_error();
            $loginids_disabled_failed .= $client->loginid . ' ';
        }
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
        BOM::Platform::Event::Emitter::emit(
            'new_crypto_address',
            {
                loginid => $client->loginid,
            });
    }
    catch {
        log_exception();
        warn "Error caught in set_account_currency: $@\n";
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

    my $old_financial_assessment = decode_fa($client->financial_assessment());

    update_financial_assessment($client->user, $params->{args});

    # This is here to continue sending scores through our api as we cannot change the output of our calls. However, this should be removed with v4 as this is not used by front-end at all
    my $response = build_financial_assessment($params->{args})->{scores};

    $response->{financial_information_score} = delete $response->{financial_information};
    $response->{trading_score}               = delete $response->{trading_experience};

    my %changed_items;
    foreach my $key (keys %{$params->{args}}) {
        if (!exists($old_financial_assessment->{$key}) || $params->{args}->{$key} ne $old_financial_assessment->{$key}) {
            $changed_items{$key} = $params->{args}->{$key};
        }
    }
    delete $changed_items{set_financial_assessment};

    BOM::Platform::Event::Emitter::emit(
        'set_financial_assessment',
        {
            loginid => $client->loginid,
            params  => \%changed_items,
        }) if (%changed_items);
    return $response;
};

rpc get_financial_assessment => sub {
    my $params = shift;

    my $client = $params->{client};
    # We should return FA for VRTC that has financial or gaming account
    # Since we have independent financial and gaming.
    my @siblings = grep { not $_->is_virtual } $client->user->clients(include_disabled => 0);
    return BOM::RPC::v3::Utility::permission_error() if ($client->is_virtual and not @siblings);
    my $response;
    foreach my $sibling (@siblings) {
        if ($sibling->financial_assessment()) {
            $response = decode_fa($sibling->financial_assessment());
            last;
        }
    }

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

1;

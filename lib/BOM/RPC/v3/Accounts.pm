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
use Array::Utils    qw( intersect );
use List::Util      qw(  any  sum0  first  min  uniq  none  );
use Digest::SHA     qw( hmac_sha256_hex );
use Text::Trim      qw( trim );
use JSON::MaybeUTF8 qw( decode_json_utf8 encode_json_utf8);
use URI;
use List::Util qw(any);

use BOM::User::Client;
use BOM::User::FinancialAssessment
    qw(is_section_complete update_financial_assessment decode_fa build_financial_assessment APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD);
use LandingCompany::Registry;
use Format::Util::Numbers            qw/formatnumber financialrounding/;
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode log_exception get_verification_uri);
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::EmailVerification qw(email_verification);
use BOM::Transaction::History       qw(get_transaction_history);
use BOM::Platform::Context          qw (localize request);
use BOM::Platform::Client::CashierValidation;
use BOM::Config::Runtime;
use BOM::Platform::Email  qw(send_email);
use BOM::Platform::Locale qw/get_state_by_id/;
use BOM::User;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Token;
use BOM::Platform::Token::API;
use BOM::Platform::Utility;
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
use BOM::Config::AccountType::Registry;
use BOM::RPC::v3::Services;
use BOM::RPC::v3::Services::Onramp;
use BOM::Config::Redis;
use BOM::User::Onfido;
use BOM::User::IdentityVerification;
use BOM::Rules::Engine;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::TradingPlatform::CTrader;

use Locale::Country;
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);

use constant DEFAULT_STATEMENT_LIMIT         => 100;
use constant DOCUMENT_EXPIRING_SOON_INTERVAL => '1mo';

# Expected withdrawal processing times in days [min, max].
use constant WITHDRAWAL_PROCESSING_TIMES => {
    bank_wire => [5, 10],
    doughflow => {
        VISA       => [5, 15],
        MasterCard => [5, 15],
        ZingPay    => [1, 2],
    },
};

# Set this to zero to *disable* any attempt to read the MT5 account
# balances. This only affects the balance API call: it does not block other
# other RPC calls which retrieve lists of accounts.
use constant MT5_BALANCE_CALL_ENABLED => 0;
use constant CHANGE_EMAIL_TOKEN_TTL   => 3600;

my $compliance_config = BOM::Config::Compliance->new;

my $email_field_labels = {
    exclude_until          => 'Exclude from website until',
    max_balance            => 'Maximum account cash balance',
    max_turnover           => 'Daily turnover limit',
    max_losses             => 'Daily limit on losses',
    max_deposit            => 'Daily limit on deposit',
    max_7day_turnover      => '7-day turnover limit',
    max_7day_losses        => '7-day limit on losses',
    max_7day_deposit       => '7-day limit on deposit',
    max_30day_turnover     => '30-day turnover limit',
    max_30day_losses       => '30-day limit on losses',
    max_30day_deposit      => '30-day limit on deposit',
    max_open_bets          => 'Maximum number of open positions',
    session_duration_limit => 'Session duration limit, in minutes',
};

# max deposit limits are named differently in websocket API and database
my $max_deposit_key_mapping = {
    max_deposit       => 'max_deposit_daily',
    max_7day_deposit  => 'max_deposit_7day',
    max_30day_deposit => 'max_deposit_30day',
};

my $json = JSON::MaybeXS->new;

requires_auth('trading', 'wallet');

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
    auth => [],    # unauthenticated
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
    #
    # Do not use LandingCompany::Registry::get_default() here because the default landing company is virtual
    # and it only has USD as the currency.
    my $client_landing_company =
        (defined $params->{landing_company_name})
        ? LandingCompany::Registry->by_name($params->{landing_company_name})
        : LandingCompany::Registry->by_name('svg');
    my $lc = $client ? $client->landing_company : $client_landing_company;

    # ... but we fall back to `svg` as a useful default, since it has most
    # currencies enabled.

    # Remove cryptocurrencies that have been suspended
    return BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);
    };

rpc "landing_company",
    auth => [],    # unauthenticated
    sub {
    my $params   = shift;
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

    delete @landing_company{qw/is_signup_allowed idd_country alpha3/};

    $landing_company{id} = $country;

    foreach my $type ('gaming_company', 'financial_company') {
        if (($landing_company{$type} // 'none') ne 'none') {
            $landing_company{$type} = __build_landing_company(LandingCompany::Registry->by_name($landing_company{$type}), $country);
        } else {
            delete $landing_company{$type};
        }
    }

    # mt5 structure as per country config
    # 'mt' => {
    #    'gaming' => {
    #         'standard' => ['none']
    #    },
    #    'financial' => {
    #         'stp' => ['none'],
    #         'standard' => ['none']
    #    }
    # }
    #
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
    my %output_map                  = (
        stp       => 'financial_stp',
        standard  => 'financial',
        swap_free => 'swap_free',
    );

    foreach my $mt5_type (keys %{$mt5_landing_company_details}) {
        foreach my $mt5_sub_type (keys %{$mt5_landing_company_details->{$mt5_type}}) {
            # We need to keep the API backward compatible. Current API doesn't support multiple
            # landing companies (counter parties) for one account type. So, we will return the default.
            my $company_name = $mt5_landing_company_details->{$mt5_type}{$mt5_sub_type}[0];
            next if not $company_name or $company_name eq 'none';

            $landing_company{"mt_${mt5_type}_company"}{$output_map{$mt5_sub_type}} =
                __build_landing_company(LandingCompany::Registry->by_name($company_name), $country);
        }
    }

    my $dx_details = delete $landing_company{dx};

    foreach my $dx_market_type (keys %$dx_details) {
        foreach my $dx_sub_type (keys $dx_details->{$dx_market_type}->%*) {
            my $dx_lc = $dx_details->{$dx_market_type}{$dx_sub_type};
            next if $dx_lc eq 'none';
            $landing_company{"dxtrade_${dx_market_type}_company"}{$dx_sub_type} =
                __build_landing_company(LandingCompany::Registry->by_name($dx_lc), $country);
        }
    }

    delete $landing_company{wallet};

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
    auth => [],    # unauthenticated
    sub {
    my $params = shift;

    my $country = $params->{args}->{country} // "default";

    my $lc = LandingCompany::Registry->by_name($params->{args}->{landing_company_details});
    return BOM::RPC::v3::Utility::create_error({
            code              => 'UnknownLandingCompany',
            message_to_client => localize('Unknown landing company.')}) unless $lc;

    return __build_landing_company($lc, $country);
    };

=head2 _lc_country_requires_tin

check if the country for the provided landing company is (NPJ) Non Participating Jurisdiction 
and TIN is mandatory or not.

=cut

sub _lc_country_requires_tin {
    my ($landing_company, $country) = @_;

    my $npj_countries_list = $compliance_config->get_npj_countries_list;
    my $tin_not_mandatory  = 0;

    if (any { $country eq $_ } $npj_countries_list->{$landing_company}->@*) {
        $tin_not_mandatory = 1;
    }
    return $tin_not_mandatory;
}

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

=item * support_professional_client

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

=item * support_professional_client

=back

Returns a hashref of landing_company parameters

=cut

sub __build_landing_company {
    my $lc = shift;
    # If no country is given, it will return the legal allowed markets of the landing company
    # else it will return the legal allowed markets for the given country
    my $country = shift // "default";

    # Check if the country is NPJ for the landing company
    # NPJ = TIN is not required for the combination of Country + Landing Company

    my $tin_not_mandatory = _lc_country_requires_tin($lc->short, $country);

    # Get suspended currencies and remove them from list of legal currencies
    my $payout_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);

    my $result = {
        shortcode                         => $lc->short,
        name                              => $lc->name,
        address                           => $lc->address,
        country                           => $lc->country,
        legal_default_currency            => $lc->legal_default_currency,
        legal_allowed_currencies          => $payout_currencies,
        legal_allowed_markets             => $lc->legal_allowed_markets(BOM::Config::Runtime->instance->get_offerings_config, $country),
        legal_allowed_contract_categories => $lc->legal_allowed_contract_categories,
        has_reality_check                 => $lc->has_reality_check ? 1 : 0,
        currency_config                   => market_pricing_limits($payout_currencies, $lc->short, $lc->legal_allowed_markets),
        requirements                      => $lc->requirements,
        changeable_fields                 => $lc->changeable_fields,
        support_professional_client       => $lc->support_professional_client
    };

    if ($country ne "default") {
        $result->{tin_not_mandatory} = $tin_not_mandatory;
    }

    return $result;
}

=head2 _withdrawal_details

Takes transaction hash ($txn) and returns additional withdrawal details if applicable

=cut

sub _withdrawal_details {
    my $txn = shift;

    my $gateway   = $txn->{payment_gateway_code} // return;
    my $details   = $txn->{details}              // return;
    my $df_method = $details->{payment_method}   // '';

    my $durations;
    $durations = WITHDRAWAL_PROCESSING_TIMES->{$gateway}             if $gateway eq 'bank_wire';
    $durations = WITHDRAWAL_PROCESSING_TIMES->{$gateway}{$df_method} if $gateway eq 'doughflow';
    return unless $durations;

    # estimated processing times are business days. We double the max to allow for holidays and unusual circumstances.
    my $days     = $durations->[1] * 2;
    my $end_date = Date::Utility->new($txn->{transaction_time})->plus_time_interval($days . 'd');

    if (Date::Utility->new->is_before($end_date)) {
        return localize('Typical processing time is [_1] to [_2] business days.', @$durations);
    }
}

rpc "statement",
    category => 'account',
    sub {
    my $params = shift;

    {
        # Send metrics to understand how users are using this call
        my $args                = $params->{args};
        my $duration_in_seconds = 0;
        $duration_in_seconds = $args->{date_to} - $args->{date_from} if ($args->{date_to}   && $args->{date_from});
        $duration_in_seconds = time - $args->{date_from}             if ($args->{date_from} && !$args->{date_to});
        # make it -1 if there is only date_to
        $duration_in_seconds = -1 if ($args->{date_to} && !$args->{date_from});

        my $action_type      = $args->{action_type} // 'all';
        my $first_page       = $args->{offset}      ? 0 : 1;
        my $with_description = $args->{description} ? 1 : 0;

        my $tags = ["action_type:$action_type", "with_description:$with_description", "first_page:$first_page"];
        stats_gauge("bom_rpc.v_3.statement.analysis.duration", $duration_in_seconds,                      {tags => $tags});
        stats_gauge("bom_rpc.v_3.statement.analysis.limit",    $args->{limit} // DEFAULT_STATEMENT_LIMIT, {tags => $tags});
    }

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

    my $transactions = get_transaction_history($params);
    return {
        transactions => [],
        count        => 0
    } unless $transactions;

    my $currency_code = $client->default_account->currency_code();

    my @short_codes = grep { defined $_ } map { $_->{short_code} } @$transactions;
    my $longcodes;
    $longcodes = longcode({
            short_codes => \@short_codes,
            currency    => $currency_code,
        }) if scalar @short_codes;

    my @result;
    for my $txn (@$transactions) {

        my $struct = {
            balance_after    => formatnumber('amount', $currency_code, $txn->{balance_after}),
            transaction_id   => $txn->{id},
            reference_id     => $txn->{buy_tr_id},
            contract_id      => $txn->{financial_market_bet_id},
            transaction_time => $txn->{transaction_time},
            action_type      => $txn->{action_type},
            amount           => $txn->{amount},
            payout           => $txn->{payout_price},
            $txn->{fees} ? (fees => $txn->{fees}) : (),
            $txn->{from} ? (from => $txn->{from}) : (),
            $txn->{to}   ? (to   => $txn->{to})   : (),
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
                $struct->{longcode} = $txn->{payment_remark};
            }
            $struct->{shortcode} = $txn->{short_code};

            my $withdrawal_details = _withdrawal_details($txn);
            $struct->{withdrawal_details} = $withdrawal_details if $withdrawal_details;
        }

        $struct->{app_id} = BOM::RPC::v3::Utility::mask_app_id($txn->{source}, $txn->{transaction_time});

        push @result, $struct;
    }

    return {
        transactions => \@result,
        count        => scalar @result
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
    } catch ($e) {
        warn "Error caught : $e\n";
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
            $trx{shortcode}     = $row->{short_code};
            $trx{longcode}      = $res->{longcodes}->{$row->{short_code}} // localize('Could not retrieve contract details');
            $trx{duration_type} = (shortcode_to_parameters($trx{shortcode}, $client->currency))->{duration_type};
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
    my $params      = shift;
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
                status           => 0,
            };
            next;
        }

        my $converted = convert_currency($sibling->account->balance, $sibling->account->currency_code, $total_currency);
        $real_total += $converted unless $sibling->is_virtual;
        $demo_total += $converted if $sibling->is_virtual;

        $response->{accounts}{$sibling->loginid} = {
            currency                        => $sibling->account->currency_code,
            balance                         => formatnumber('amount', $sibling->account->currency_code, $sibling->account->balance),
            converted_amount                => formatnumber('amount', $total_currency,                  $converted),
            account_id                      => $sibling->account->id,
            demo_account                    => $sibling->is_virtual ? 1 : 0,
            type                            => 'deriv',
            currency_rate_in_total_currency => convert_currency(1, $sibling->account->currency_code, $total_currency)
            ,    # This rate is used for the future stream
            status => 1,
        };
    }

    my $mt5_real_total = 0;
    my $mt5_demo_total = 0;

    if (_mt5_balance_call_enabled()) {
        my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($params->{client})->else(sub { return Future->done(); })->get;

        for my $mt5_account (@mt5_accounts) {
            if (my $error = $mt5_account->{error}) {
                my $mt5_login    = $error->{details}{login};
                my $account_type = BOM::MT5::User::Async::get_account_type($mt5_login);
                $response->{accounts}{$mt5_login} = {
                    currency         => '',
                    balance          => '0.00',
                    converted_amount => '0.00',
                    type             => 'mt5',
                    demo_account     => $account_type eq 'demo' ? 1 : 0,
                    status           => 0,
                };
            } else {
                my $is_demo   = $mt5_account->{group} =~ /^demo/ ? 1 : 0;
                my $converted = convert_currency($mt5_account->{balance}, $mt5_account->{currency}, $total_currency);
                $is_demo ? $mt5_demo_total : $mt5_real_total += $converted;

                $response->{accounts}{$mt5_account->{login}} = {
                    currency                        => $mt5_account->{currency},
                    balance                         => formatnumber('amount', $mt5_account->{currency}, $mt5_account->{balance}),
                    converted_amount                => formatnumber('amount', $total_currency,          $converted),
                    demo_account                    => $is_demo,
                    type                            => 'mt5',
                    currency_rate_in_total_currency => convert_currency(1, $mt5_account->{currency}, $total_currency)
                    ,    # This rate is used for the future stream
                    status => 1,
                };
            }
        }
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

    my $client                     = $params->{client};
    my $risk_aml                   = $client->risk_level_aml;
    my $risk_sr                    = $client->risk_level_sr;
    my $status                     = $client->status->visible;
    my $id_auth_status             = $client->authentication_status;
    my $authentication_in_progress = $id_auth_status =~ /under_review|needs_action/;

    # some clients were withdrawal locked for high aml risk;
    # but their risk level has dropped before they could authenticate their accounts.
    # this flag is used to let them get correct instructions in the FE.
    my $was_locked_for_high_risk = $client->was_locked_for_high_risk;

    my $is_withdrawal_locked_for_fa =
        $client->status->withdrawal_locked && $client->status->withdrawal_locked->{reason} =~ /FA needs to be completed/;

    push @$status, 'document_' . $id_auth_status if $authentication_in_progress;

    if ($client->fully_authenticated()) {
        push @$status, 'authenticated';
        # we send this status as client is already authenticated
        # so they can view or upload more documents if needed
        push @$status, 'allow_document_upload';
    } elsif ($client->landing_company->is_authentication_mandatory
        or $risk_aml eq 'high'
        or $risk_sr eq 'high'
        or ($client->status->withdrawal_locked and not $is_withdrawal_locked_for_fa)
        or $client->status->allow_document_upload
        or $client->locked_for_false_profile_info)
    {
        push @$status, 'allow_document_upload';
    }

    # check if there is a dup client to grab the financial assessment from
    # and also idv_disallowed flag

    my $duplicated;

    $duplicated = $client->duplicate_sibling_from_vr if $client->is_virtual;

    my $idv_client = $duplicated // $client;

    push @$status, 'idv_disallowed' if BOM::User::IdentityVerification::is_idv_disallowed($idv_client);

    my $user = $client->user;

    my $provider;
    if ($user->{has_social_signup}) {
        push @$status, 'social_signup';    # differentiate between social and password based accounts
        my $user_connect = BOM::Database::Model::UserConnect->new;
        $provider = $user_connect->get_connects_by_user_id($client->user->{id})->[0];
    }
    my $fa_client = $duplicated // $client;

    # push age verification status if the duplicated has got it
    push @$status, 'skip_idv' if $duplicated && $duplicated->status->age_verification;
    push @$status, 'skip_idv' if $duplicated && !BOM::User::IdentityVerification->new(user_id => $duplicated->binary_user_id)->submissions_left;

    # check whether the user need to perform financial assessment
    my $client_fa = decode_fa($fa_client->financial_assessment());

    push(@$status, 'financial_information_not_complete')
        unless $fa_client->is_financial_information_complete();

    push(@$status, 'trading_experience_not_complete')
        unless is_section_complete($client_fa, "trading_experience", $fa_client->landing_company->short);

    push(@$status, 'financial_assessment_not_complete') unless $fa_client->is_financial_assessment_complete();

    push(@$status, 'mt5_password_not_set') unless $client->user->trading_password;

    push(@$status, 'dxtrade_password_not_set') unless $client->user->dx_trading_password;

    push(@$status, 'needs_affiliate_coc_approval') if $client->user->affiliate_coc_approval_required;

    push(@$status, 'p2p_blocked_for_pa') if $client->payment_agent && !$client->get_payment_agent->service_is_allowed('p2p');

    my $age_verif_client = $duplicated // $client;

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        stop_on_failure => 0
    );
    my %args = (
        loginid     => $client->loginid,
        action      => '',
        is_internal => 0,
        is_cashier  => 1,
        rule_engine => $rule_engine
    );
    my $base_validation     = BOM::Platform::Client::CashierValidation::validate(%args);
    my $deposit_validation  = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    my $withdraw_validation = BOM::Platform::Client::CashierValidation::validate(%args, action => 'withdrawal');

    $withdraw_validation->{status} //= [];
    $withdraw_validation->{status} = [map { $_ =~ s/^ServiceNotAllowedForPA$/WithdrawServiceUnavailableForPA/r } $withdraw_validation->{status}->@*];

    my @cashier_validation     = uniq map { ($_->{status} // [])->@* } $base_validation, $deposit_validation, $withdraw_validation;
    my @cashier_missing_fields = uniq map { ($_->{missing_fields} // [])->@* } $deposit_validation, $withdraw_validation;

    if ($was_locked_for_high_risk) {
        push @cashier_validation, 'ASK_AUTHENTICATE'            unless $client->fully_authenticated;
        push @cashier_validation, 'FinancialAssessmentRequired' unless $client->is_financial_assessment_complete;
    }

    if ($base_validation->{error} or ($deposit_validation->{error} and $withdraw_validation->{error})) {
        # Skip adding the cashier_locked status only if there is one status from the validation and its ExperimentalCurrency
        push @$status, 'cashier_locked' unless (scalar @cashier_validation == 1 and $cashier_validation[0] eq 'ExperimentalCurrency');
    } elsif ($deposit_validation->{error}) {
        push @$status, 'deposit_locked';
    } elsif ($withdraw_validation->{error}) {
        push @$status, 'withdrawal_locked';
    }

    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password) {
        push(@$status, 'password_reset_required') unless $client->status->migrated_universal_password;
    }

    my $has_mt5_regulated_account         = $user->has_mt5_regulated_account();
    my $is_document_expiry_check_required = $client->is_document_expiry_check_required_mt5(has_mt5_regulated_account => $has_mt5_regulated_account);
    my $is_verification_required          = $client->is_verification_required(
        check_authentication_status => 1,
        has_mt5_regulated_account   => $has_mt5_regulated_account,
        risk_aml                    => $was_locked_for_high_risk ? 'high' : $risk_aml,
        risk_sr                     => $risk_sr
    );
    my $authentication = _get_authentication(
        client                            => $client,
        is_document_expiry_check_required => $is_document_expiry_check_required,
        is_verification_required          => $is_verification_required,
        risk_aml                          => $was_locked_for_high_risk ? 'high' : $risk_aml,
        risk_sr                           => $risk_sr
    );

    if ($is_document_expiry_check_required) {
        # check if the user's documents are expired or expiring soon
        my $expiry_soon_date = Date::Utility->new()->plus_time_interval(DOCUMENT_EXPIRING_SOON_INTERVAL)->epoch;
        if ($authentication->{identity}{status} eq 'expired') {
            push(@$status, 'document_expired');
        } elsif ($authentication->{identity}{expiry_date} && $expiry_soon_date > $authentication->{identity}{expiry_date}) {
            push(@$status, 'document_expiring_soon');
        }
    }
    my %currency_config = map {
        $_ => {
            is_deposit_suspended    => BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $_),
            is_withdrawal_suspended => BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $_),
        }
    } $client->currency;

    if ($client->status->age_verification || $client->fully_authenticated) {
        $status = [grep { $_ ne 'poi_name_mismatch' } @$status];
    }

    my $p2p_status = "none";
    if (my $advertiser = $client->_p2p_advertiser_cached) {
        $p2p_status = "active";
        if (not $advertiser->{is_enabled}) {
            $p2p_status = "perm_ban";
        } elsif ($advertiser->{blocked_until}) {
            my $block_time = Date::Utility->new($advertiser->{blocked_until});
            $p2p_status = "temp_ban" if $block_time->epoch > time;
        }
    }

    if ($client->status->age_verification || $client->fully_authenticated) {
        $status = [grep { $_ ne 'poi_dob_mismatch' } @$status];
    }

    return {
        status                        => [sort(uniq(@$status))],
        risk_classification           => $risk_sr eq 'high' ? $risk_sr : $risk_aml // '',
        prompt_client_to_authenticate => $is_verification_required,
        authentication                => $authentication,
        currency_config               => \%currency_config,
        @cashier_validation     ? (cashier_validation       => [sort(uniq(@cashier_validation))])     : (),
        @cashier_missing_fields ? (cashier_missing_fields   => [sort(uniq(@cashier_missing_fields))]) : (),
        $provider               ? (social_identity_provider => $provider)                             : (),
        p2p_status => $p2p_status,
    };
};

=head2 _get_authentication

Gets the authentication object for the given client.

It takes the following named params:

=over 4

=item * C<client> the client itself

=item * C<is_document_expiry_check_required> indicates if `expired` status is allowed for the given client

=back

Returns,
    a hashref with the following structure:

=over 4

=item * C<needs_verification> an arrayref that can hold 'identity' and/or 'document', they indicate that POI and/or POA are required respectively

=item * C<identity> a hashref containing the current POI situation

=item * C<document> a hashref containing the current POA situation

=back

Both 'identity' and 'document' share a C<status> and an optional C<expiry_date> (as timestamp),
meanwhile 'identity' also offers a C<services> structure which indicates the current
onfido configuration.

Possible C<status> values:

=over 4

=item * C<none> no POI/POA

=item * C<expired> POI only, the POI has expired

=item * C<pending> the POI/POA is waiting for validation

=item * C<rejected> the POI/POA has been rejected

=item * C<suspected> POI only, the POI is fishy

=item * C<verified> there is a valid POI/POA

=back

=cut

sub _get_authentication {
    my %args = @_;

    my $client                = $args{client};
    my $authentication_object = {
        needs_verification => [],
        identity           => {
            status   => "none",
            services => {
                onfido => {
                    submissions_left     => 0,
                    is_country_supported => 0,
                    documents_supported  => [],
                    last_rejected        => [],
                    reported_properties  => {},
                    status               => 'none',
                },
                idv => {
                    submissions_left    => 0,
                    last_rejected       => [],
                    reported_properties => {},
                    status              => 'none',
                },
                manual => {
                    status => 'none',
                }
            },
        },
        document => {
            status => "none",
        },
        ownership => {
            status   => "none",
            requests => [],
        },
        income => {
            status => "none",
        },
        attempts => {
            count   => 0,
            history => [],
            latest  => undef
        },
    };

    return $authentication_object if $client->is_virtual;
    # Each key from the authentication object will be filled up independently by an assembler method.
    # The `needs_verification` array can be filled with `identity` and/or `document`, there is a method for each one.
    my $documents = $client->documents->uploaded();
    my $poo_list  = $client->proof_of_ownership->full_list();
    my $args      = {
        client    => $client,
        documents => $documents,
        poo_list  => $poo_list,
    };
    # Resolve the POA
    $authentication_object->{document} = _get_authentication_poa($args);
    # Resolve the POI
    $authentication_object->{identity} = _get_authentication_poi($args);
    # Resolve the POO
    $authentication_object->{ownership} = _get_authentication_poo($args);
    # Resolve the POW proof of wealth/income
    $authentication_object->{income} = _get_authentication_pow($args);
    # Current statuses
    my $poa_status = $authentication_object->{document}->{status};
    my $poi_status = $authentication_object->{identity}->{status};
    # The `needs_verification` array is built from the following hash keys
    my %needs_verification_hash;
    $needs_verification_hash{identity}  = 1 if $client->needs_poi_verification($documents, $poi_status, $args{is_verification_required});
    $needs_verification_hash{document}  = 1 if $client->needs_poa_verification($documents, $poa_status, $args{is_verification_required});
    $needs_verification_hash{ownership} = 1 if $client->proof_of_ownership->needs_verification($poo_list);
    $needs_verification_hash{income}    = 1 if $client->needs_pow_verification($documents);
    # Craft the `needs_verification` array
    $authentication_object->{needs_verification} = [sort keys %needs_verification_hash];
    # Craft the `attempts` object
    $authentication_object->{attempts} = $client->poi_attempts;
    return $authentication_object;
}

=head2 _get_authentication_poo

Resolves the C<proof_of_ownership> structure of the authentication object.

It takes the following named params:

=over 4

=item * C<client> - a L<BOM::User::Client> the client itself

=item * C<poo_list> - the POO list that belongs to the client itself and needs to be fulfilled

=back

Returns,
    hashref containing the structure needed for C<proof_of_ownership> at the authentication object.

=cut

sub _get_authentication_poo {
    my $params = shift;
    my ($client, $poo_list) = @{$params}{qw/client poo_list/};
    my $poo_status = $client->proof_of_ownership->status($poo_list);

    # Return the proof_of_ownership structure
    return {
        status   => $poo_status,
        requests => [
            map  { {documents_required => _get_poo_documents_required($_), %$_{qw/id payment_method creation_time/}} }
            grep { $_->{status} eq 'pending' || $_->{status} eq 'rejected'; } $poo_list->@*
        ],
    };
}

=head2 _get_poo_documents_required

Resolves the number of documents required for a given poo.

It takes the following named params:

=over 4

=item * POO - The Proof of Ownserhip Record


=back

Returns,
    Number of documents required to be uploaded

=cut

sub _get_poo_documents_required {
    my ($poo) = @_;

    my %documents_required = (
        astropay    => 2,
        onlinenaira => 2,
    );

    my $pm = lc $poo->{payment_method};

    return $documents_required{$pm} // 1;
}

=head2 _get_authentication_poi

Resolves the C<identity> structure of the authentication object.

It takes the following named params:

=over 4

=item * L<BOM::User::Client> the client itself

=item * C<documents> hashref containing the client documents by type


=back

Returns,
    hashref containing the structure needed for C<document> at authentication object.

=cut

sub _get_authentication_poi {
    my $params = shift;
    my ($client, $documents) = @{$params}{qw/client documents/};
    my $poi_expiry_date      = $documents->{proof_of_identity}->{expiry_date};
    my $expiry_date          = $poi_expiry_date ? $poi_expiry_date : undef;
    my $country_code         = uc($client->place_of_birth || $client->residence // '');
    my $poi_status           = $client->get_poi_status($documents);
    my $country_code_triplet = uc(Locale::Country::country_code2code($country_code, LOCALE_CODE_ALPHA_2, LOCALE_CODE_ALPHA_3) // "");

    my $last_rejected = [];
    push $last_rejected->@*, BOM::User::Onfido::get_consider_reasons($client)->@* if $poi_status =~ /rejected|suspected/;
    push $last_rejected->@*, BOM::User::Onfido::get_rules_reasons($client)->@*;

    my $idv_details = _get_idv_service_detail($client);
    my ($latest_poi_by) = $client->latest_poi_by();
    $latest_poi_by //= '';
    $expiry_date   //= $idv_details->{expiry_date} if $latest_poi_by eq 'idv';

    my $rejected_onfido_reasons = BOM::Platform::Utility::rejected_onfido_reasons();

    # Return the identity structure
    return {
        status   => $poi_status,
        services => {
            idv    => $idv_details,
            onfido => {
                submissions_left     => BOM::User::Onfido::submissions_left($client),
                is_country_supported => BOM::Config::Onfido::is_country_supported($country_code),
                documents_supported  => BOM::Config::Onfido::supported_documents_for_country($country_code),
                last_rejected        =>
                    [uniq map { defined $rejected_onfido_reasons->{$_} ? localize($rejected_onfido_reasons->{$_}) : () } $last_rejected->@*],
                reported_properties => BOM::User::Onfido::reported_properties($client),
                status              => $client->get_onfido_status($documents),
                $country_code_triplet ? (country_code => $country_code_triplet) : (),
            },
            manual => {
                status => $client->get_manual_poi_status($documents),
            },
        },
        defined $expiry_date ? (expiry_date => $expiry_date) : (),
    };
}

=head2 _get_idv_service_detail

Gets Identity verification service details from database and wrap them in the manner format for returning to user

=cut

sub _get_idv_service_detail {
    my ($client) = @_;

    my $idv      = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
    my $document = $idv->get_last_updated_document();
    my $expiration_date;
    my $idv_reject_reasons;
    my $reported_properties;
    my $status;

    if ($document) {
        $expiration_date = eval { Date::Utility->new($document->{document_expiration_date})->epoch } if $document->{document_expiration_date};
        $status          = $client->get_idv_status($document);

        if ($status eq 'rejected') {
            my $messages = eval { decode_json_utf8($document->{status_messages} // '[]') };

            my $rejected_identity_verification_reasons = BOM::Platform::Utility::rejected_identity_verification_reasons();

            $idv_reject_reasons = [
                map  { $rejected_identity_verification_reasons->{$_} ? localize($rejected_identity_verification_reasons->{$_}) : () }
                grep { $_ } $messages->@*
            ];
        }
    }

    my $submissions_left = $idv->submissions_left();

    # automatically give 1 attempt if doc is expired and no submissions are left
    $submissions_left = $idv->has_expired_document_chance() ? 1 : 0 if $submissions_left <= 0 && $client->get_idv_status() eq 'expired';

    return {
        submissions_left    => $submissions_left,
        last_rejected       => $idv_reject_reasons  // [],
        status              => $status              // 'none',
        reported_properties => $reported_properties // {},
        defined $expiration_date ? (expiry_date => $expiration_date) : ()};
}

=head2 _get_authentication_poa

Resolves the C<document> structure of the authentication object.

It takes the following named params:

=over 4

=item * L<BOM::User::Client> the client itself

=item * C<documents> hashref containing the client documents by type

=back

Returns,
    hashref containing the structure needed for C<document> at authentication object.

=cut

sub _get_authentication_poa {
    my $params = shift;
    my ($client, $documents) = @{$params}{qw/client documents/};

    # Return the document structure
    return {
        status => $client->get_poa_status($documents),
    };
}

=head2 _get_authentication_pow

Resolves the C<document> structure of the authentication object.

It takes the following named params:

=over 4

=item * L<BOM::User::Client> the client itself

=item * C<documents> hashref containing the client documents by type

=back

Returns,
    hashref containing the structure needed for C<document> at authentication object.

=cut

sub _get_authentication_pow {
    my $params = shift;
    my ($client, $documents) = @{$params}{qw/client documents/};

    # Return the document structure
    return {
        status => $client->get_pow_status($documents),
    };
}

rpc change_email => sub {
    my $params = shift;
    my $client = $params->{client};
    my ($token_type, $client_ip, $args) = @{$params}{qw/token_type client_ip args/};
    my $brand = request()->brand;
    # allow OAuth token
    unless (($token_type // '') eq 'oauth_token') {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $user = $client->user;
    $args->{new_email} = lc $args->{new_email} if $args->{new_email};
    if ($args->{change_email} eq 'verify') {
        my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code},
            $client->email, 'request_email', 0, $client->binary_user_id)->{error};
        if ($err) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => $err->{code},
                    message_to_client => $err->{message_to_client}});
        }

        my $erring_user = BOM::User->new(email => $args->{new_email});
        if ($erring_user) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => "InvalidEmail",
                    message_to_client => localize("This email is already in use. Please use a different email.")});
        }

        # send token to new email
        my $code = BOM::Platform::Token->new({
                email       => $args->{new_email},
                expires_in  => CHANGE_EMAIL_TOKEN_TTL,
                created_for => 'request_email',
                created_by  => $client->binary_user_id,
            })->token;
        my $uri    = get_verification_uri($params->{source}) // '';
        my $params = [
            action => $user->{has_social_signup} ? 'social_email_change' : 'system_email_change',
            code   => $code,
            lang   => request()->language,
            email  => $args->{new_email}];
        if ($uri) {
            my $url = URI->new($uri);
            $url->query_form(@$params);
            $uri = $url->as_string;
        }

        _send_change_email_verification_email(
            $client, 'verify_change_email',
            code                  => $code,
            uri                   => $uri,
            time_to_expire_in_min => CHANGE_EMAIL_TOKEN_TTL / 60,
            email                 => $args->{new_email},
            social_signup         => $user->{has_social_signup} // '',
            live_chat_url         => $brand->live_chat_url
        );

    } elsif ($args->{change_email} eq 'update') {
        my $error = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code},
            $args->{new_email}, 'request_email', 0, $client->binary_user_id)->{error};
        if ($error) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => $error->{code},
                    message_to_client => $error->{message_to_client}});
        }

        if ($args->{new_password}) {
            my $password_error = BOM::RPC::v3::Utility::check_password({
                email        => $client->email,
                new_password => $args->{new_password} // ''
            });
            return $password_error if $password_error;
        }

        if (!$args->{new_password} && $user->{has_social_signup}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => "PasswordError",
                    message_to_client => localize("Unable to update email, password required for social login.")});
        }

        try {
            $client->user->update_email($args->{new_email});
            if ($args->{new_password}) {
                $client->user->update_user_password($args->{new_password});
            }

            my $default_client = $user->get_default_client(
                include_disabled   => 1,
                include_duplicated => 1
            );
            my $default_client_loginid = $default_client->loginid;
            BOM::Platform::Event::Emitter::emit('sync_user_to_MT5',    {loginid => $default_client_loginid});
            BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $default_client_loginid}) unless $default_client->is_virtual;

            my @properties = (
                $client, 'confirm_change_email',
                social_signup => $user->{has_social_signup} // '',
                live_chat_url => $brand->live_chat_url,
                email         => $args->{new_email});

            $user->unlink_social if $user->{has_social_signup};
            _send_change_email_verification_email(@properties);

        } catch {
            log_exception();
            return BOM::RPC::v3::Utility::create_error({
                code              => 'EmailChangeError',
                message_to_client =>
                    localize("We were unable to make the changes due to an error on our server. Please try again in a few minutes."),
            });
        }
    }
    return {status => 1};
};

=head2 _send_change_email_verification_email

Sends change email confirm email to the user.

It takes the following params:

=over 4

=item * C<client> A L<BOM::User::Client> instance.

=item * C<event> The event to be emitted.

=item * C<event_args> A hash containg event arguments.

=back

Returns undef.

=cut

sub _send_change_email_verification_email {
    my ($client, $event, %event_args) = @_;
    die unless defined $event;
    BOM::Platform::Event::Emitter::emit(
        $event,
        {
            loginid    => $client->loginid,
            properties => {
                first_name            => $client->first_name,
                email                 => $event_args{email},
                code                  => $event_args{code}                  // '',
                verification_uri      => $event_args{uri}                   // '',
                live_chat_url         => $event_args{live_chat_url}         // '',
                time_to_expire_in_min => $event_args{time_to_expire_in_min} // '',
                social_signup         => $event_args{social_signup} ? 1 : 0,
            }});
    return undef;
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

    my $err = BOM::RPC::v3::Utility::check_password({
            email        => $client->email,
            old_password => $args->{old_password},
            new_password => $args->{new_password},
            user_pass    => $user->{password}});
    return $err if $err;

    try {
        $client->user->update_user_password($args->{new_password}, 'change_password');
        _send_reset_password_confirmation_email($client, 'change_password');
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordChangeError',
            message_to_client => localize("We were unable to change your password due to an unexpected error. Please try again."),
        });
    }

    return {status => 1};
};

rpc "reset_password",
    auth => [],    # unauthenticated
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

    if (
        my $pass_error = BOM::RPC::v3::Utility::check_password({
                email        => $email,
                new_password => $args->{new_password}}))
    {
        return $pass_error;
    }

    try {
        $client->user->update_user_password($args->{new_password}, 'reset_password');
        _send_reset_password_confirmation_email($client, 'reset_password');
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordResetError',
            message_to_client => localize("We were unable to reset your password due to an unexpected error. Please try again."),
        });
    }

    # if user have social signup and decided to proceed, update has_social_signup to false
    if ($user->{has_social_signup}) {
        $user->unlink_social;
    }

    return {status => 1};
    };

=head2 _send_reset_password_confirmation_email

Sends reset or change password confirmation email to the user.

It takes the following named params:

=over 4

=item * C<client> A L<BOM::User::Client> instance.

=item * C<type> 'reset_password' or 'change_password'

=back

Returns undef.

=cut

sub _send_reset_password_confirmation_email {
    my ($client, $type) = @_;
    BOM::Platform::Event::Emitter::emit(
        'reset_password_confirmation',
        {
            loginid    => $client->loginid,
            properties => {
                first_name => $client->first_name,
                email      => $client->email,
                type       => $type,
            }});
    return undef;
}

rpc get_settings => sub {
    my $params = shift;
    my $client = $params->{client};

    my ($dob_epoch, $country_code, $country);
    $dob_epoch = Date::Utility->new($client->date_of_birth)->epoch if ($client->date_of_birth);
    if ($client->residence) {
        $country_code = $client->residence;
        $country      = request()->brand->countries_instance->countries->localized_code2country($client->residence, $params->{language});
    }

    my $user = $client->user;

    my $cooling_off_period =
        BOM::Config::Redis::redis_replicated_read()->ttl(APPROPRIATENESS_TESTS_COOLING_OFF_PERIOD . $client->{binary_user_id});

    # grab from dup account
    my $duplicated;

    $duplicated = $client->duplicate_sibling;

    my $fa_client = $duplicated // $client;

    my $financial_assessment = $fa_client->financial_assessment() // '';
    $financial_assessment = decode_fa($financial_assessment) if $financial_assessment;

    my $settings = {
        email     => $user->email,
        country   => $country,
        residence => $country
        , # Everywhere else in our responses to FE, we pass the residence key instead of country. However, we need to still pass in country for backwards compatibility.
        country_code       => $country_code,
        email_consent      => ($user and $user->{email_consent}) ? 1 : 0,
        preferred_language => $user->preferred_language,
        trading_hub        => $client->status->trading_hub ? 1 : 0,
        feature_flag       => $user->get_feature_flag,
        immutable_fields   => [$client->immutable_fields()],
        ($client->citizen ? (citizen => $client->citizen) : ()),
        (
              ($user and BOM::Config::third_party()->{elevio}{account_secret})
            ? (user_hash => hmac_sha256_hex($user->email, BOM::Config::third_party()->{elevio}{account_secret}))
            : ())};

    my @clients = grep { $_ and not $_->is_virtual } $user->clients(include_disabled => 0), $client->duplicate_sibling_from_vr;

    if ($cooling_off_period > 0) {
        $settings->{cooling_off_expiration_date} = time + $cooling_off_period;
    }

    if ($financial_assessment && $financial_assessment->{employment_status} && $fa_client->landing_company->short eq 'maltainvest') {
        $settings->{employment_status} = $financial_assessment->{employment_status};
    }

    my $dxtrade_suspend = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;
    my ($real_client) = sort { $b->date_joined cmp $a->date_joined } @clients;

    if ($real_client) {
        # We should pick the information from the first created account for
        # account settings attributes/fields that sync between clients - personal information
        # And, use current client to return account settings attributes/fields
        # for others, like is_authenticated_payment_agent, since they account specific
        $settings = {
            has_secret_answer              => defined $real_client->secret_answer ? 1 : 0,
            salutation                     => $real_client->salutation,
            first_name                     => $real_client->first_name,
            last_name                      => $real_client->last_name,
            address_line_1                 => $real_client->address_1,
            address_line_2                 => $real_client->address_2,
            address_city                   => $real_client->city,
            address_state                  => $real_client->state,
            address_postcode               => $real_client->postcode,
            phone                          => $real_client->phone,
            place_of_birth                 => $real_client->place_of_birth,
            tax_residence                  => $real_client->tax_residence,
            tax_identification_number      => $real_client->tax_identification_number,
            account_opening_reason         => $real_client->account_opening_reason,
            date_of_birth                  => $real_client->date_of_birth ? Date::Utility->new($real_client->date_of_birth)->epoch : undef,
            citizen                        => $real_client->citizen  // '',
            allow_copiers                  => $client->allow_copiers // 0,
            non_pep_declaration            => $client->non_pep_declaration_time ? 1 : 0,
            client_tnc_status              => $client->accepted_tnc_version,
            request_professional_status    => $client->status->professional_requested                            ? 1 : 0,
            dxtrade_user_exception         => (any { $user->email eq $_ } $dxtrade_suspend->user_exceptions->@*) ? 1 : 0,
            is_authenticated_payment_agent =>
                ($client->payment_agent and $client->payment_agent->status and $client->payment_agent->status eq 'authorized') ? 1 : 0,
            %$settings,
        };
    }
    return $settings;
};

rpc set_settings => sub {
    my $params = shift;

    my $current_client = $params->{client};

    my ($website_name, $client_ip, $user_agent, $language, $args) =
        @{$params}{qw/website_name client_ip user_agent language args/};
    $user_agent //= '';

    # This function used to find the fields updated to send them as properties to track event
    # TODO Please rename this to updated_fields once you refactor this function to remove deriv set settings email.
    my $updated_fields_for_track = _find_updated_fields($params);

    my $brand              = request()->brand;
    my $countries_instance = request()->brand->countries_instance();
    my ($residence, $allow_copiers) =
        ($args->{residence}, $args->{allow_copiers});
    my $tax_residence             = $args->{'tax_residence'}             // $current_client->tax_residence             // '';
    my $tax_identification_number = $args->{'tax_identification_number'} // $current_client->tax_identification_number // '';
    my $employment_status         = $args->{'employment_status'};
    # Residence is used in validating other fields like address_state
    $args->{residence} ||= $current_client->residence;
    unless ($current_client->is_virtual) {
        my $error = $current_client->format_input_details($args);
        return BOM::RPC::v3::Utility::create_error_by_code($error->{error}) if $error;
    }

    my $required_fields = $current_client->landing_company->requirements->{signup} // [];
    my %required_values = map { $_ => $current_client->$_ } @$required_fields;
    my $rule_engine     = BOM::Rules::Engine->new(client => $current_client);
    try {
        $rule_engine->verify_action(
            'set_settings',
            loginid => $current_client->loginid,
            %required_values, %$args
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    };

    # If a virtual account's residence is empty, it can accept a new value;
    # But for real accounts it's not possbile to set residence at all.
    if ($current_client->is_virtual and not $current_client->residence and $residence) {
        $current_client->residence($residence);
        if (not $current_client->save()) {
            return BOM::RPC::v3::Utility::client_error();
        }
    }

    # only allow current client to set allow_copiers
    if (defined $allow_copiers) {
        $current_client->allow_copiers($allow_copiers);
        return BOM::RPC::v3::Utility::client_error() unless $current_client->save();
    }

    my $user = $current_client->user;

    $user->update_preferred_language($args->{preferred_language}) if $args->{preferred_language};
    $user->set_feature_flag($args->{feature_flag})                if $args->{feature_flag};

    # Set trading_hub as a client status_code if the user has it enabled
    if (defined $args->{trading_hub}) {
        my $siblings = $current_client->get_siblings_information();
        for my $each_sibling (keys %{$siblings}) {
            my $client = BOM::User::Client->new({loginid => $each_sibling});
            $client->status->setnx('trading_hub', 'system', 'Enabling the Trading Hub') if $args->{trading_hub} == 1;
            $client->status->clear_trading_hub                                          if $args->{trading_hub} == 0;
        }
    }

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined $args->{email_consent}) {
        $user->update_email_fields(email_consent => $args->{email_consent});
    }

    # Shold not allow client to change TIN number if we have TIN format for the country and it doesnt match
    # In case of having more than a tax residence, client residence will replaced.
    my $selected_tax_residence = $tax_residence =~ /\,/g ? $current_client->residence : $tax_residence;
    my $now                    = Date::Utility->new;
    my $address1               = $args->{'address_line_1'}                                 // $current_client->address_1;
    my $address2               = ($args->{'address_line_2'} // $current_client->address_2) // '';
    my $addressTown            = $args->{'address_city'}                                   // $current_client->city;
    my $addressState           = ($args->{'address_state'} // $current_client->state)      // '';
    my $addressPostcode        = $args->{'address_postcode'}                               // $current_client->postcode;
    my $phone                  = ($args->{'phone'} // $current_client->phone)              // '';
    my $birth_place            = $args->{place_of_birth}                                   // $current_client->place_of_birth;
    my $date_of_birth          = $args->{date_of_birth}                                    // $current_client->date_of_birth;
    my $citizen                = ($args->{'citizen'} // $current_client->citizen)          // '';
    my $salutation             = $args->{'salutation'}                                     // $current_client->salutation;
    my $first_name             = trim($args->{'first_name'} // $current_client->first_name);
    my $last_name              = trim($args->{'last_name'}  // $current_client->last_name);
    my $account_opening_reason = $args->{'account_opening_reason'} // $current_client->account_opening_reason;
    my $secret_answer          = $args->{secret_answer} ? BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) : '';
    my $secret_question        = $args->{secret_question} // '';

    # If this is a virtual account update, we don't want to change anything else - otherwise
    # let's apply the new fields to all other accounts as well.
    my @loginids = ();
    if ($current_client->is_virtual) {
        push @loginids, $user->bom_virtual_loginid        if $user->bom_virtual_loginid;
        push @loginids, $user->bom_virtual_wallet_loginid if $user->bom_virtual_wallet_loginid;
    } else {
        push @loginids, $user->bom_real_loginids if $user->bom_real_loginids;
    }

    # set professional status for applicable countries
    if ($args->{request_professional_status}) {
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
        # Send an email to contact the client
        _send_request_professional_status_confirmation_email(
            $current_client,
            'professional_status_requested',
            loginid                     => $current_client->loginid,
            request_professional_status => $args->{request_professional_status}) if $current_client->fully_authenticated;
    }

    foreach my $loginid (@loginids) {
        my $client = $loginid eq $current_client->loginid ? $current_client : BOM::User::Client->new({loginid => $loginid});

        $client->address_1($address1)                            if $address1;
        $client->address_2($address2)                            if $address2;
        $client->city($addressTown)                              if $addressTown;
        $client->state($addressState)                            if defined $addressState;
        $client->postcode($addressPostcode)                      if defined $args->{'address_postcode'};
        $client->phone($phone)                                   if length $phone;
        $client->citizen($citizen)                               if $citizen;
        $client->place_of_birth($birth_place)                    if $birth_place;
        $client->account_opening_reason($account_opening_reason) if $account_opening_reason;
        $client->date_of_birth($date_of_birth)                   if $date_of_birth;
        $client->salutation($salutation)                         if $salutation;
        $client->first_name($first_name)                         if $first_name;
        $client->last_name($last_name)                           if $last_name;
        $client->secret_answer($secret_answer)                   if $secret_answer;
        $client->secret_question($secret_question)               if $secret_question;

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

    # Send request to update onfido details (only for reals)
    unless ($current_client->is_virtual) {
        BOM::Platform::Event::Emitter::emit('check_onfido_rules',  {loginid => $current_client->loginid});
        BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $current_client->loginid});
    }

    if (defined $employment_status && $current_client->landing_company->short eq 'maltainvest') {
        my $data_to_be_saved = {employment_status => $employment_status};
        my @all_clients      = $user->clients();
        foreach my $cli (@all_clients) {
            $current_client->set_financial_assessment($data_to_be_saved);
        }
    }

    # send email only if there was any changes
    if (scalar keys %$updated_fields_for_track) {
        BOM::Platform::Event::Emitter::emit(
            'profile_change',
            {
                loginid    => $current_client->loginid,
                properties => {
                    updated_fields => $updated_fields_for_track,
                    origin         => 'client',
                    live_chat_url  => $brand->live_chat_url({
                            source   => $params->{source},
                            language => $params->{language}}
                    ),
                }});

        BOM::User::AuditLog::log('Your settings have been updated successfully', $current_client->loginid);
        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $current_client->loginid});

        BOM::Platform::Event::Emitter::emit('check_name_changes_after_first_deposit', {loginid => $current_client->loginid})
            if any { $_ eq 'first_name' or $_ eq 'last_name' } keys %$updated_fields_for_track;

        BOM::Platform::Event::Emitter::emit(
            'sync_mt5_accounts_status',
            {
                binary_user_id => $current_client->binary_user_id,
                client_loginid => $current_client->loginid
            });
    }

    # check if newly added address matches expected
    if ($args->{'address_line_1'} || $args->{'address_line_2'}) {
        if ($current_client->documents->is_poa_address_fixed()) {
            $current_client->documents->poa_address_fix();
        }
    }

    return {status => 1};
};

=head2 _send_request_professional_status_confirmation_email

Sends the first email once client requested for professional status

It takes the following params:

=over 4

=item * C<client> A L<BOM::User::Client> instance.

=item * C<event> The event to be emitted.

=item * C<event_args> A hash containg event arguments.

=back

Returns undef.

=cut

sub _send_request_professional_status_confirmation_email {
    my ($client, $event, %event_args) = @_;
    die unless defined $event;
    BOM::Platform::Event::Emitter::emit(
        $event,
        {
            loginid    => $client->loginid,
            properties => {
                first_name                  => $client->first_name,
                email                       => $client->email,
                request_professional_status => $event_args{request_professional_status} ? 1 : 0,
            }});
    return undef;
}

rpc get_self_exclusion => sub {
    my $params = shift;

    my $client = $params->{client};
    return _get_self_exclusion_details($client);
};

sub _contains_any {
    my ($hash, @keys) = (@_);
    scalar grep { exists $hash->{$_} } @keys;
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
        for my $setting (
            qw/max_balance max_turnover max_open_bets max_losses max_7day_losses
            max_7day_turnover max_30day_losses max_30day_turnover session_duration_limit/
            )
        {
            $get_self_exclusion->{$setting} = $self_exclusion->$setting + 0 if $self_exclusion->$setting;
        }

        if ($client->landing_company->deposit_limit_enabled) {
            for my $api_key (qw/max_deposit max_7day_deposit max_30day_deposit/) {
                my $db_key = $max_deposit_key_mapping->{$api_key};
                $get_self_exclusion->{$api_key} = $self_exclusion->$db_key + 0 if $self_exclusion->$db_key;
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

    my %args = %{$params->{args}};

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        $rule_engine->verify_action(
            'set_self_exclusion',
            loginid => $client->loginid,
            %args
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

    # get old from above sub _get_self_exclusion_details
    my $self_exclusion = _get_self_exclusion_details($client);

    # Max balance and Max open bets are given default values, if not set by client
    $self_exclusion->{max_balance}   //= $client->get_limit_for_account_balance;
    $self_exclusion->{max_open_bets} //= $client->get_limit_for_open_positions;

    my $is_regulated = $client->landing_company->is_eu;

    my $error_sub = sub {
        my ($error, $field) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => $error,
            message           => '',
            details           => $field
        });
    };

    my $validation_error_sub = sub {
        my ($field, $message, $detail) = @_;
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InputValidationFailed',
                message_to_client => $message // localize("Input validation failed: [_1].", $field),
                message           => '',
                details           => {
                    $field => $detail // localize("Please input a valid number."),
                },
            });
    };

    ## validate
    my %fields = (
        numerical => {(
                map { $_ => {is_integer => 0} } (
                    qw/max_balance max_turnover max_losses max_deposit max_7day_turnover max_7day_losses max_7day_deposit max_30day_losses max_30day_turnover max_30day_deposit/
                )
            ),
            max_open_bets => {
                is_integer => 1,
            },
            session_duration_limit => {
                is_integer => 1,
                max        => {
                    value   => 6 * 7 * 24 * 60,                                                   # a six-week interval in minutes
                    message => localize('Session duration limit cannot be more than 6 weeks.'),
                },
            },
            timeout_until => {
                is_integer => 1,
                min        => {
                    value   => time(),
                    message => localize('Timeout time must be greater than current time.'),
                },
                max => {
                    value   => time() + 6 * 7 * 24 * 60 * 60,                                     # six weeks later's epoch
                    message => localize('Timeout time cannot be more than 6 weeks.'),
                },
            },
        },
        date => {
            exclude_until => {
                after_today => {
                    message => localize('Exclude time must be after today.'),
                },
                min => {
                    value   => Date::Utility->new->plus_time_interval('6mo'),
                    message => localize('Exclude time cannot be less than 6 months.'),
                },
                max => {
                    value   => Date::Utility->new->plus_time_interval('5y'),
                    message => localize('Exclude time cannot be for more than five years.'),
                }
            },
        },
    );

    my @all_fields = map { keys $fields{$_}->%* } (qw /numerical date/);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'SetSelfExclusionError',
            message_to_client => localize('Please provide at least one self-exclusion setting.'),
        }) if none { defined $args{$_} } @all_fields;

    my $decimals = Format::Util::Numbers::get_precision_config()->{price}->{$client->currency};
    for my $field (keys $fields{numerical}->%*) {
        my $value = $args{$field};

        next unless defined $value;

        my $field_settings = $fields{numerical}->{$field};

        my $regex = $field_settings->{is_integer} ? qr/^\d+$/ : qr/^\d{0,20}(?:\.\d{0,$decimals})?$/;
        return $validation_error_sub->($field) unless $value =~ $regex;

        # zero value is unconditionally accepatable for unregulated landing companies (limit removal)
        next if not $is_regulated and 0 == $value;

        my ($min, $max) = @$field_settings{qw/min max/};
        return $error_sub->($min->{message}, $field) if $min and $value < $min->{value};
        return $error_sub->($max->{message}, $field) if $max and $value > $max->{value};

        # accept any max value if unregulated account and the field is not 'max_open_bets'
        next if (not $is_regulated and $field ne 'max_open_bets');

        # in regulated landing companies, clients are not allowed to extend or remove their self-exclusion settings
        # non-regulated clients are allowed to extend max_open_bets up to default max value
        if ($self_exclusion->{$field}) {
            $min = $field_settings->{is_integer} ? 1 : 0;
            $max = $self_exclusion->{$field};
            if (not $is_regulated and $field eq 'max_open_bets') {
                $max = BOM::Config::client_limits()->{max_open_bets_default};
            }

            return $error_sub->(localize('Please enter a number between [_1] and [_2].', $min, $max), $field)
                if $value <= 0 or $value > $max;
        }
    }

    for my $field (keys $fields{date}->%*) {
        my $value = $args{$field};

        next unless defined $value;

        # empty value is unconditionally accepatable for unregulated landing companies (limit removal)
        next unless $is_regulated or $value;

        my $field_settings = $fields{date}->{$field};

        my $field_date = eval { Date::Utility->new($value) };

        return $validation_error_sub->($field, localize('Exclusion time conversion error.'), localize('Invalid date format.'))
            unless $field_date;

        return $error_sub->($field_settings->{after_today}->{message}, $field) if $field_date->is_before(Date::Utility->new);

        my $min = $field_settings->{min};
        return $error_sub->($min->{message}, $field) if $min->{value} and $field_date->is_before($min->{value});

        my $max = $field_settings->{max};
        return $error_sub->($max->{message}, $field) if $max->{value} and $field_date->is_after($max->{value});
    }

    for my $field (@all_fields) {
        my $db_field = $max_deposit_key_mapping->{$field} // $field;
        $client->set_exclusion->$db_field($args{$field} || undef)
            if exists $args{$field};
    }

    $client->save();

    # RTS 12 - Financial Limits - max turover limit is mandatory for UK Clients and MLT clients
    # If the limit is set, restrictions can be lifted by removing the pertaining status.
    my $config = request()->brand->countries_instance->countries_list->{$client->residence};
    $client->status->clear_max_turnover_limit_not_set()
        if $args{max_30day_turnover}
        and ($config->{need_set_max_turnover_limit}
        or $client->landing_company->check_max_turnover_limit_is_set);

    if (defined $args{exclude_until} && $client->user->email_consent) {
        BOM::Config::Runtime->instance->app_config->check_for_update();

        my $data_subscription = {
            loginid      => $client->loginid,
            unsubscribed => 1,
        };

        BOM::Platform::Event::Emitter::emit('email_subscription', $data_subscription);
    }

# Need to send email in 1 circumstance:
#   - Any MX/MLT/MF client sets a self exclusion period && balance > 0

    my $balance;
    if ($client->default_account) {
        $balance = $client->default_account->balance;
    } else {
        $balance = '0.00';
    }

    if ($args{exclude_until} and $client->landing_company->short eq 'maltainvest') {
        # send exclude_until email for MF only
        warn 'Compliance email regarding self exclusion from the website failed to send.'
            unless send_self_exclusion_notification($client, 'self_exclusion', \%args, $balance);
    }

    return {status => 1};
};

=head2 send_self_exclusion_notification

Sends email to compliance and/or payments to
inform about client's self exclusion

Takes the following parameters:

=over 4

=item * C<$client> a L<BOM::User::Client> object

=item * C<$type>, which can be one of the following:

=over 4

=item * self_exclusion

=back

=back

=over 4

=item * C<$args> a hash, which contains the client's self exclusion choices:

=over 4

=item * set_self_exclusion

=item * exclude_until

=item * max_30day_deposit

=item * max_30day_losses

=item * max_30day_turnover

=item * max_7day_deposit

=item * max_7day_losses

=item * max_7day_turnover

=item * max_balance

=item * max_deposit

=item * max_losses

=item * max_open_bets

=item * max_turnover

=item * session_duration_limit

=item * timeout_until

=back

=item * C<balance>, client's acccount balance

=back

In success sends email to compliance and/or payments
else returns 0

=cut

sub send_self_exclusion_notification {
    my ($client, $type, $args, $balance) = @_;

    $balance = $balance // 0;
    my @fields_to_email;
    my $message;
    if ($type eq 'self_exclusion') {
        $message         = "A user has excluded themselves from the website.\n";
        @fields_to_email = qw/exclude_until/;
    }

    if (@fields_to_email) {
        my $statuses     = join '/',  map { uc $_ } @{$client->status->all};
        my $client_title = join ', ', $client->loginid, ($statuses ? "current status: [$statuses]" : '');

        my $brand = request()->brand;

        $message .= "Client $client_title set the following self-exclusion limits:\n\n";

        foreach (@fields_to_email) {
            my $label = $email_field_labels->{$_};
            my $val   = $args->{$_};
            $message .= "$label: $val\n" if $val;
        }

        my $to_email = $brand->emails('compliance');

        # Include accounts team if client's brokercode is MX
        # As per UKGC LCCP Audit Regulations
        if (   $client->landing_company->self_exclusion_notify
            && $args->{exclude_until}
            && $balance > 0)
        {

            $message  .= "\n\nClient's account balance is: $balance\n\n";
            $to_email .= ',' . $brand->emails('accounting');

        }

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
        my $token  = $m->create_token($client->loginid, $display_name, $scopes, ($args->{valid_for_current_ip_only} ? $client_ip : undef));

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
            } catch ($e) {
                my $err_code = $e->{error_code} // '';

                if (my $message = $BOM::RPC::v3::P2P::ERROR_MAP{$err_code}) {
                    push @service_futures,
                        Future->fail(
                        BOM::RPC::v3::Utility::create_error({
                                code              => $err_code,
                                message_to_client => localize($message),
                            }));
                }
                push @service_futures, Future->fail($e);
            }
        }

        if ($service eq 'onfido') {
            my $referrer    = $args->{referrer} // $params->{referrer};
            my $country     = $args->{country}  // $params->{country} // $client->place_of_birth // $client->residence;
            my $country_tag = $country ? uc(country_code2code($country, 'alpha-2', 'alpha-3')) : '';
            my $tags        = ["country:$country_tag"];

            # The requirement for the format of <referrer> is https://*.<DOMAIN>/*
            # as stated in https://documentation.onfido.com/#generate-web-sdk-token
            $referrer =~ s/(\/\/).*?(\..*?)(\/|$).*/$1\*$2\/\*/g;
            stats_inc(
                'rpc.onfido.service_token.dispatch',
                {
                    tags => $tags,
                });

            push @service_futures,
                BOM::RPC::v3::Services::service_token(
                $client,
                {
                    service  => $service,
                    referrer => $referrer,
                    country  => $country,
                }
            )->then(
                sub {
                    my ($result) = @_;
                    if ($result->{error}) {
                        stats_inc(
                            'rpc.onfido.service_token.failure',
                            {
                                tags => $tags,
                            });
                        return Future->fail($result->{error});
                    } else {
                        stats_inc(
                            'rpc.onfido.service_token.success',
                            {
                                tags => $tags,
                            });
                        return Future->done({
                            token   => $result->{token},
                            service => 'onfido',
                        });
                    }
                });
        }

        if ($service =~ /^(banxa|wyre)$/) {
            my $onramp = BOM::RPC::v3::Services::Onramp->new(service => $service);
            push @service_futures, $onramp->create_order($params)->then(
                sub {
                    my ($result) = @_;
                    if ($result->{error}) {
                        return Future->fail($result->{error});
                    } else {
                        return Future->done({
                            service => $service,
                            %$result
                        });
                    }
                });
        }

        if ($service eq 'dxtrade') {

            try {
                my $trading_platform = BOM::TradingPlatform->new(
                    platform => 'dxtrade',
                    client   => $client
                );

                push @service_futures,
                    Future->done({
                        service => $service,
                        token   => $trading_platform->generate_login_token($args->{server}),
                    });

            } catch ($e) {
                my $error = BOM::RPC::v3::Utility::create_error_by_code($e->{error_code});
                push @service_futures, Future->fail($error);
            }

        }

        if ($service eq 'pandats') {
            push @service_futures,
                BOM::RPC::v3::Services::service_token(
                $client,
                {
                    service => $service,
                    server  => $args->{server},
                }
            )->then(
                sub {
                    my ($result) = @_;
                    if ($result->{error}) {
                        return Future->fail($result->{error});
                    } else {
                        return Future->done({
                            token   => $result->{token},
                            service => 'pandats',
                        });
                    }
                });
        }

        if ($service eq 'ctrader') {
            try {
                my $ctrader = BOM::TradingPlatform::CTrader->new(client => $client);

                push @service_futures,
                    Future->done({
                        token   => $ctrader->generate_login_token($params->{ua_fingerprint}),
                        service => 'ctrader',
                    });
            } catch ($e) {
                push @service_futures, Future->fail($e);
            }
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

    my ($client, $args) = @{$params}{qw/client args/};

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    try {
        if ($args->{affiliate_coc_agreement}) {

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'AffiliateNotFound',
                    message_to_client => localize('You have not registered as an affiliate.')}) unless defined $client->user->affiliate;

            $client->user->set_affiliate_coc_approval;

        } elsif ($args->{ukgc_funds_protection}) {
            return BOM::RPC::v3::Utility::client_error()
                unless (eval { $client->status->set('ukgc_funds_protection', 'system', 'Client acknowledges the protection level of funds'); });
        } else {
            $client->user->set_tnc_approval;
        }
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::client_error();
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

    my $user                = $client->user;
    my @accounts_to_disable = $user->clients(include_disabled => 0);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'ReasonNotSpecified',
            message_to_client => localize('Please specify the reasons for closing your accounts.')}) if $closing_reason =~ /^\s*$/;

    # This for-loop is for balance validation, open positions checking and pending withdrawals check
    # No account is to be disabled if there is at least one real-account with balance or
    # there is a pending DF payout

    my %accounts_with_positions;
    my %accounts_with_balance;
    my %accounts_with_pending_df;
    foreach my $client (@accounts_to_disable) {
        next if ($client->is_virtual || !$client->account);

        my $number_open_contracts = scalar @{$client->get_open_contracts};
        my $balance               = $client->account->balance;
        my $pending_payouts       = $client->get_df_payouts_count;

        $accounts_with_pending_df{$client->loginid} = $pending_payouts       if $pending_payouts;
        $accounts_with_positions{$client->loginid}  = $number_open_contracts if $number_open_contracts;
        $accounts_with_balance{$client->loginid}    = {
            balance  => $balance,
            currency => $client->currency
        } if $balance > 0;
    }

    # get_mt5_logins will return the accounts from all the available trade servers.
    # If one trade server is disabled, these accounts will be marked as inaccessible.
    my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($params->{client})->else(sub { return Future->done(); })->get;
    my %mt5_accounts_inaccessible;
    foreach my $mt5_account (@mt5_accounts) {
        if ($mt5_account->{error} and $mt5_account->{error}{code} eq 'MT5AccountInaccessible') {
            $mt5_accounts_inaccessible{$mt5_account->{error}{details}{login}} = $mt5_account->{error}->{message_to_client};
            next;
        }

        next if defined $mt5_account->{group} and $mt5_account->{group} =~ /^demo/;

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

    # DXTrader check balances
    unless (BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all) {
        my $trading_platform = BOM::TradingPlatform->new(
            platform => 'dxtrade',
            client   => $client
        );
        my $dxtrader_accounts = $trading_platform->get_accounts();

        foreach my $dxtrader_account (grep { $_->{account_type} eq 'real' } $dxtrader_accounts->@*) {
            if ($dxtrader_account->{balance} > 0) {
                $accounts_with_balance{$dxtrader_account->{account_id}} = {
                    balance  => formatnumber('amount', $dxtrader_account->{currency}, $dxtrader_account->{balance}),
                    currency => $dxtrader_account->{currency},
                };
            }
            # TODO: check open positions
        }
    }

    if (%accounts_with_positions || %accounts_with_balance || %accounts_with_pending_df) {
        my @accounts_to_fix = uniq(keys %accounts_with_balance, keys %accounts_with_positions, keys %accounts_with_pending_df);
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AccountHasPendingConditions',
                message_to_client => localize(
                    'Please close open positions and withdraw all funds from your [_1] account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.',
                    join(', ', @accounts_to_fix)
                ),
                details => +{
                    %accounts_with_balance    ? (balance             => \%accounts_with_balance)    : (),
                    %accounts_with_positions  ? (open_positions      => \%accounts_with_positions)  : (),
                    %accounts_with_pending_df ? (pending_withdrawals => \%accounts_with_pending_df) : (),
                }});
    }

    if (%mt5_accounts_inaccessible) {
        my @accounts_to_fix = uniq(keys %mt5_accounts_inaccessible);
        return BOM::RPC::v3::Utility::create_error({
                code              => 'MT5AccountInaccessible',
                message_to_client => localize(
                    'The following MT5 account(s) are temporarily inaccessible: [_1]. Please try again later.', join(', ', @accounts_to_fix))});
    }

    # This for-loop is for disabling the accounts
    # If an error occurs, it will be emailed to CS to disable manually
    my $loginids_disabled_success = '';
    my $loginids_disabled_failed  = '';

    my $loginid = $client->loginid;
    my $error;

    my $oauth = BOM::Database::Model::OAuth->new;
    foreach my $client (@accounts_to_disable) {
        # revoke access_token
        $oauth->revoke_tokens_by_loginid($loginid);
        try {
            $client->status->upsert('disabled', $loginid, $closing_reason) unless $client->status->disabled;
            $client->status->upsert('closed',   $loginid, $closing_reason) unless $client->status->closed;
            $loginids_disabled_success .= $client->loginid . ' ';
        } catch {
            log_exception();
            $error = BOM::RPC::v3::Utility::client_error();
            $loginids_disabled_failed .= $client->loginid . ' ';
        }
    }
    # revoke refresh_token
    $oauth->revoke_refresh_tokens_by_user_id($user->id);

    # Return error if NO loginids have been disabled
    return $error if ($error && $loginids_disabled_success eq '');

    my $data_email_consent = {
        loginid       => $loginid,
        email_consent => 0
    };

    # Remove email consents for the user (and update the clients as well)
    $user->update_email_fields(email_consent => $data_email_consent->{email_consent});

    my $data_closure = {
        new_campaign      => 1,
        closing_reason    => $closing_reason,
        loginid           => $loginid,
        loginids_disabled => $loginids_disabled_success,
        loginids_failed   => $loginids_disabled_failed,
        email_consent     => $data_email_consent->{email_consent},
        name              => $client->first_name,
    };

    BOM::Platform::Event::Emitter::emit('account_closure', $data_closure);

    return {status => 1};
};

rpc set_account_currency => sub {
    my $params = shift;

    my ($client, $currency) = @{$params}{qw/client currency/};

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        $rule_engine->verify_action(
            'set_account_currency',
            loginid          => $client->loginid,
            currency         => $currency,
            account_category => $client->get_account_type->category->name,
            account_type     => $client->get_account_type->name,
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error, 'CurrencyTypeNotAllowed');
    };

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
    } catch ($e) {
        log_exception();
        warn "Error caught in set_account_currency: $e\n";
    }

    return {status => $status};
};

rpc set_financial_assessment => sub {
    my $params = shift;

    # This is kept here for a transitional state only
    my @new_version = qw(trading_experience trading_experience_regulated financial_information);
    my @keys        = keys $params->{args}->%*;
    my @sections;
    if (!intersect(@new_version, @keys)) {
        return _deprecated_financial_assessment($params);
    }

    my $client  = $params->{client};
    my $company = $client->landing_company->short;

    if ($company eq 'maltainvest' && $params->{args}->{trading_experience}) {
        return BOM::RPC::v3::Utility::permission_error;
    }
    if ($company ne 'maltainvest' && !$params->{args}->{financial_information}) {
        return BOM::RPC::v3::Utility::permission_error;
    }

    my $old_financial_assessment = decode_fa($client->financial_assessment());
    my $financial_assessment;
    my %changed_items;

    #extract needed params
    foreach my $fa_information (@keys) {
        # This is kept here for a transitional state only
        next unless any { $fa_information eq $_ } qw{trading_experience trading_experience_regulated financial_information};

        #disregard trading_experience value if landing company is maltainvest
        next if $fa_information eq 'trading_experience' && $company eq 'maltainvest';

        #disregard trading_experience_regulated value if landing company is not maltainvest
        next if $fa_information eq 'trading_experience_regulated' && $company ne 'maltainvest';

        next if $fa_information eq 'set_financial_assessment';
        push @sections, $fa_information;
        foreach my $key (keys %{$params->{args}->{$fa_information}}) {
            $financial_assessment->{$key} = $params->{args}->{$fa_information}->{$key};
            if (!exists($old_financial_assessment->{$key}) || $params->{args}->{$fa_information}->{$key} ne $old_financial_assessment->{$key}) {
                $changed_items{$key} = $params->{args}->{$fa_information}->{$key};
            }
        }
    }

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    try {
        $rule_engine->verify_action(
            'set_financial_assessment', $financial_assessment->%*,
            loginid => $client->loginid,
            keys    => \@sections
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

    update_financial_assessment($client->user, $financial_assessment);

    if ($company eq 'maltainvest') {
        $financial_assessment->{calculate_appropriateness} = 1;
    }

    my $response = build_financial_assessment($financial_assessment)->{scores};
    $response->{financial_information_score} = delete $response->{financial_information};

    $response->{trading_score} = delete $response->{trading_experience};

    if ($company eq 'maltainvest') {
        $response->{trading_score} = delete $response->{trading_experience_regulated};
        # if there is a change in trading experience regulated only
        if ($params->{args}->{trading_experience_regulated}) {
            $client->status->clear_financial_risk_approval();
            if ($response->{trading_score} == 0) {
                $client->status->upsert('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
            } else {
                $client->status->upsert('financial_risk_approval', 'SYSTEM', 'Financial risk approved based on financial assessment score');
            }
        }

    } else {
        delete $response->{trading_experience_regulated};
    }

    if (    $client->status->mt5_withdrawal_locked
        and $client->status->mt5_withdrawal_locked->{'reason'} =~ /FA is required for the first deposit on regulated MT5./g)
    {
        $client->status->clear_mt5_withdrawal_locked;
    }
    BOM::Platform::Event::Emitter::emit(
        'set_financial_assessment',
        {
            loginid => $client->loginid,
            params  => \%changed_items,
        }) if (%changed_items);
    return $response;
};

=head2 _deprecated_financial_assessment

This is kept here for a transitional state only

=cut

sub _deprecated_financial_assessment {
    my $params = shift;
    my $client = $params->{client};

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        $rule_engine->verify_action('set_financial_assessment', $params->{args}->%*, loginid => $client->loginid);
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

    my $old_financial_assessment = decode_fa($client->financial_assessment());

    update_financial_assessment($client->user, $params->{args});

    # This is here to continue sending scores through our api as we cannot change the output of our calls. However, this should be removed with v4 as this is not used by front-end at all
    my $response = build_financial_assessment($params->{args})->{scores};

    $response->{financial_information_score} = delete $response->{financial_information};
    $response->{trading_score}               = delete $response->{trading_experience};
    delete $response->{trading_experience_regulated};
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
}

rpc get_financial_assessment => sub {
    my $params = shift;
    my $args   = $params->{args};
    my $client = $params->{client};

    # We should return FA for VRTC that has financial or gaming account
    # Since we have independent financial and gaming.
    my @siblings = grep { not $_->is_virtual } $client->user->clients(include_disabled => 0);

    if ($client->is_virtual and not @siblings) {
        # grab from dup account
        my $duplicated = $client->duplicate_sibling_from_vr;

        push @siblings, $duplicated if $duplicated;

        return BOM::RPC::v3::Utility::permission_error() unless @siblings;
    }

    my $response;
    my $duplicated = $client->duplicate_sibling;
    push @siblings, $duplicated if $duplicated;

    foreach my $sibling (@siblings) {
        if ($sibling->financial_assessment()) {
            $response = decode_fa($sibling->financial_assessment());
            last;
        }
    }
    my $company = $client->landing_company->short;
    # This is here to continue sending scores through our api as we cannot change the output of our calls. However, this should be removed with v4 as this is not used by front-end at all
    if (keys %$response) {
        if ($company eq 'maltainvest') {
            $response->{calculate_appropriateness} = 1;
        }
        my $scores = build_financial_assessment($response)->{scores};

        $scores->{financial_information_score} = delete $scores->{financial_information};
        $scores->{trading_score}               = delete $scores->{trading_experience};

        if ($company eq 'maltainvest') {
            $scores->{trading_score} = $scores->{trading_experience_regulated};
        }
        delete $scores->{trading_experience_regulated};
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

=head2 _mt5_balance_call_method

Static method holding value of MT5_BALANCE_CALL_ENABLED

=cut

sub _mt5_balance_call_enabled {
    return MT5_BALANCE_CALL_ENABLED;
}

rpc link_wallet => sub {
    my $params = shift;
    my $args   = $params->{args};
    my $client = $params->{client};

    my $user = $client->user;

    try {
        $user->link_wallet_to_trading_account($args);
    } catch ($e) {
        chomp $e;
        log_exception();
        return BOM::RPC::v3::Utility::create_error_by_code($e);
    }

    return {status => 1};
};

rpc paymentagent_create => sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};

    delete $args->{paymentagent_create};

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        $rule_engine->verify_action('paymentagent_create', loginid => $client->loginid);
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

    my $pa = $client->set_payment_agent;
    try {
        $args = $pa->validate_payment_agent_details(%$args);
    } catch ($error) {
        unless (ref $error) {
            chomp $error;
            my $msg_params = {
                InvalidDepositCommission    => [$pa->max_pa_commission()],
                InvalidWithdrawalCommission => [$pa->max_pa_commission()],
            };
            return BOM::RPC::v3::Utility::create_error_by_code($error, ($msg_params->{$error} // [])->@*);
        }

        return BOM::RPC::v3::Utility::create_error_by_code($error->{code}, %$error, override_code => 'InputValidationFailed');
    }

    $pa->$_($args->{$_}) for keys %$args;
    $pa->application_attempts(($pa->application_attempts // 0) + 1);
    $pa->last_application_time(Date::Utility->new->db_timestamp);
    $pa->status('applied');
    $pa->save();

    # create a livechat ticket
    my $loginid = $client->loginid;
    my $brand   = request->brand;
    my $message = "Client $loginid has submitted the payment agent application form with following content:\n\n";
    for my $arg (sort keys %$args) {
        my @values = ($args->{$arg} // '');
        my $field  = $pa->details_main_field->{$arg};
        @values = map { $_->{$field} } $args->{$arg}->@* if defined($args->{$arg}) && ref($args->{$arg}) eq 'ARRAY';
        $message .= "\n $arg: " . join(',', sort @values);
    }

    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('pa_livechat'),
        subject => "Payment agent application submitted by $loginid",
        message => ["$message\n"],
    });

    return {status => 1};
};

rpc paymentagent_details => sub {
    my $params = shift;

    my $client = $params->{client};
    my $payment_agent;
    my $response = {can_apply => 0};

    return $response if $client->is_virtual || !$client->account || !$client->residence;

    if ($payment_agent = $client->get_payment_agent) {
        for my $field (
            qw(payment_agent_name email phone_numbers urls supported_payment_methods information currency_code target_country max_withdrawal min_withdrawal commission_deposit commission_withdrawal status code_of_conduct_approval affiliate_id newly_authorized)
            )
        {
            $response->{$field} = $payment_agent->$field;
        }
    }

    if (!$payment_agent || $payment_agent->status eq 'rejected') {
        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $failures = $rule_engine->verify_action(
            'paymentagent_create',
            loginid             => $client->loginid,
            rule_engine_context => {stop_on_failure => 0},
        )->failed_rules;

        if (@$failures) {
            $response->{eligibilty_validation} = [map { $_->{error_code} } grep { ref $_ eq 'HASH' } @$failures];
        } else {
            $response->{can_apply} = 1;
        }
    }

    return $response;
};

rpc get_account_types => sub {
    my ($args, $client) = shift->@{qw(args client)};

    my $country         = $client->residence;
    my $landing_company = $args->{company} // $client->landing_company->short;
    my $brand           = request()->brand;

    if ($brand->countries_instance->restricted_country($country)) {
        return {error => {code => 'RestrictedCountry'}};
    }

    my %result = (
        wallet  => +{},
        trading => +{});
    my $wallet_types =
        BOM::Config::AccountType::Registry->category_by_name('wallet')->get_account_types_for_regulation($landing_company, $country, $brand);

    my %supported_wallets;
    for my $type ($wallet_types->@*) {
        $result{wallet}->{$type->name} = $type->get_details($landing_company);
        $supported_wallets{$type->name} = 1;
    }

    my $trading_types =
        BOM::Config::AccountType::Registry->category_by_name('trading')->get_account_types_for_regulation($landing_company, $country, $brand);
    for my $type ($trading_types->@*) {
        $result{trading}->{$type->name} = $type->get_details($landing_company);

        $result{trading}{$type->name}{linkable_wallet_types} =
            [grep { $supported_wallets{$_} } $result{trading}{$type->name}{linkable_wallet_types}->@*];
    }

    return \%result;
};

rpc get_available_accounts_to_transfer => sub {

    return {
        account_list => [{
                "account_type" => "trading",
                "loginid"      => "CR176299",
                "type"         => "fiat",
                "currency"     => "USD"
            },
            {
                "account_type" => "wallet",
                "loginid"      => "CRW2132132",
                "type"         => "crypto",
                "currency"     => "BTC"
            }]};
};

rpc "unsubscribe_email",
    auth => [],    # unauthenticated
    sub {
    my $params = shift;

    my $checksum       = $params->{args}->{checksum};
    my $binary_user_id = $params->{args}->{binary_user_id};

    my $user;
    try {
        $user = BOM::User->new(id => $binary_user_id);
    } catch {
        log_exception();
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidUser',
            message_to_client => localize('Your User ID appears to be invalid.')}) unless $user;

    my $generated_checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($binary_user_id, $user->email);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidChecksum',
            message_to_client => localize('The security hash used in your request appears to be invalid.')}) unless $generated_checksum eq $checksum;

    # Remove email consents for the user on request

    $user->update_email_fields(email_consent => 0);
    my @all_loginid = $user->loginids();

    # after update notify customer io
    my $data_subscription = {
        loginid      => $all_loginid[0],
        unsubscribed => 1,
    };
    BOM::Platform::Event::Emitter::emit('email_subscription', $data_subscription);

    return {
        email_unsubscribe_status => $user->email_consent ? 0 : 1,
        binary_user_id           => $binary_user_id
    };

    };
1;

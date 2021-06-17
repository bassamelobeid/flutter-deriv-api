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
use Array::Utils qw(intersect);
use List::Util qw(any sum0 first min uniq none);
use Digest::SHA qw(hmac_sha256_hex);
use Text::Trim qw(trim);

use BOM::User::Client;
use BOM::User::FinancialAssessment qw(is_section_complete update_financial_assessment decode_fa build_financial_assessment);
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);

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
use BOM::RPC::v3::Services::Onramp;
use BOM::Config::Redis;
use BOM::User::Onfido;
use BOM::User::IdentityVerification;
use BOM::Rules::Engine;

use Locale::Country;
use DataDog::DogStatsd::Helper qw(stats_gauge);

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

my $allowed_fields_for_virtual = qr/set_settings|email_consent|residence|allow_copiers|non_pep_declaration|preferred_language|feature_flag/;
my $email_field_labels         = {
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
        citizen                   => localize("Your citizenship cannot be changed."),
        account_opening_reason    => localize("Your account opening reason cannot be changed."),
        secret_answer             => localize("Your secret answer cannot be changed."),
        secret_question           => localize("Your secret question cannot be changed."),
        tax_residence             => localize("Your tax residence cannot be changed."),
        tax_identification_number => localize("Your tax identification number cannot be changed."),
    );
};

our %RejectedOnfidoReasons = do {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        'data_comparison.first_name'                    => localize("The name on your document doesn't match your profile."),
        'data_comparison.last_name'                     => localize("The name on your document doesn't match your profile."),
        'data_comparison.date_of_birth'                 => localize("The date of birth on your document doesn't match your profile."),
        'data_comparison.date_of_expiry'                => localize("Your document has expired."),
        'data_comparison.issuing_country'               => localize("Your document appears to be invalid."),
        'data_comparison.document_type'                 => localize("Your document appears to be invalid."),
        'data_comparison.document_numbers'              => localize("Your document appears to be invalid."),
        'visual_authenticity.original_document_present' =>
            localize("Your document appears to be a scanned copy that contains markings or text that shouldn't be on your document."),
        'visual_authenticity.original_document_present.scan' => localize(
            "We're unable to verify the document you provided because it contains markings or text that should not be on your document. Please provide a clear photo or a scan of your original identity document."
        ),
        'visual_authenticity.original_document_present.document_on_printed_paper' => localize("Your document appears to be a printed copy."),
        'visual_authenticity.original_document_present.screenshot'                => localize("Your document appears to be a screenshot."),
        'visual_authenticity.original_document_present.photo_of_screen' => localize("Your document appears to be a photo of a device screen."),
        'visual_authenticity.fonts'                                     => localize("Your document appears to be invalid."),
        'visual_authenticity.face_detection'                            => localize("Your document appears to be invalid."),
        'visual_authenticity.security_features'                         => localize("Your document appears to be invalid."),
        'visual_authenticity.template'                                  => localize("Your document appears to be invalid."),
        'visual_authenticity.digital_tampering'                         => localize("Your document appears to be invalid."),
        'visual_authenticity.picture_face_integrity'                    => localize("Your document appears to be invalid."),
        'data_validation.date_of_birth'               => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'data_validation.document_expiration'         => localize("Your document has expired."),
        'data_validation.document_numbers'            => localize("Some details in your document appear to be invalid, missing, or unclear."),
        'data_validation.no_document_numbers'         => localize("The serial number of your document couldn't be verified."),
        'data_validation.expiry_date'                 => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'data_validation.mrz'                         => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality' => localize("Your document appears to be invalid."),
        'image_integrity.conclusive_document_quality.missing_back' =>
            localize("The back of your document appears to be missing. Please include both sides of your identity document."),
        'image_integrity.conclusive_document_quality.digital_document'                => localize("Your document appears to be a digital document."),
        'image_integrity.conclusive_document_quality.punctured_document'              => localize("Your document appears to be damaged or cropped."),
        'image_integrity.conclusive_document_quality.corner_removed'                  => localize("Your document appears to be damaged or cropped."),
        'image_integrity.conclusive_document_quality.watermarks_digital_text_overlay' =>
            localize("Your document contains markings or text that should not be on your document."),
        'image_integrity.conclusive_document_quality.abnormal_document_features' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality.obscured_security_features' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality.obscured_data_points' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.colour_picture' =>
            localize("Your document appears to be in black and white. Please upload a colour photo of your document."),
        'image_integrity.supported_document' =>
            localize("The document you provided is not supported for your country. Please provide a supported document for your country."),
        'image_integrity.image_quality' =>
            localize("The image quality of your document is too low. Please provide a hi-res photo of your identity document."),
        'image_integrity.image_quality.dark_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.glare_on_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.blurred_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.covered_photo' => localize(
            "We're unable to verify the document you provided because some details appear to be missing. Please try again or provide another document."
        ),
        'image_integrity.image_quality.other_photo_issue' => localize(
            "We're unable to verify the document you provided because some details appear to be missing. Please try again or provide another document."
        ),
        'image_integrity.image_quality.damaged_document' => localize(
            "We're unable to verify the document you provided because it appears to be damaged. Please try again or upload another document."),
        'image_integrity.image_quality.incorrect_side' =>
            localize("The front of your document appears to be missing. Please provide both sides of your identity document."),
        'image_integrity.image_quality.cut_off_document' => localize(
            "We're unable to verify the document you provided because it appears to be damaged. Please try again or upload another document."),
        'image_integrity.image_quality.no_document_in_image' => localize(
            "We're unable to verify the document you provided because it appears to be a blank image. Please try again or upload another document."),
        'image_integrity.image_quality.two_documents_uploaded' =>
            localize("The document you provided appears to be two different types. Please try again or provide another document."),
        'compromised_document'                => localize("Your document failed our verification checks."),
        'age_validation.minimum_accepted_age' => localize(
            "Your age in the document you provided appears to be below 18 years. We're only allowed to offer our services to clients above 18 years old, so we'll need to close your account. If you have a balance in your account, contact us via live chat and we'll help to withdraw your funds before your account is closed."
        ),
        'selfie' => localize(
            "Your selfie isn't clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
    );
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
    my $client_landing_company =
        (defined $params->{landing_company_name})
        ? LandingCompany::Registry::get($params->{landing_company_name})
        : LandingCompany::Registry::get_default();
    my $lc = $client ? $client->landing_company : $client_landing_company;

    # ... but we fall back to `svg` as a useful default, since it has most
    # currencies enabled.

    # Remove cryptocurrencies that have been suspended
    return BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);
    };

rpc "landing_company",
    auth => [],    # unauthenticated
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

    delete $landing_company{is_signup_allowed};

    $landing_company{id} = $country;
    my $registry = LandingCompany::Registry->new;

    foreach my $type ('gaming_company', 'financial_company') {
        if (($landing_company{$type} // '') ne 'none') {
            $landing_company{$type} = __build_landing_company($registry->get($landing_company{$type}), $country);
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
                __build_landing_company($registry->get($mt5_landing_company_details->{$mt5_type}{$mt5_sub_type}), $country);
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
    auth => [],    # unauthenticated
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
    # If no country is given, it will return the legal allowed markets of the landing company
    # else it will return the legal allowed markets for the given country
    my $country = shift // "default";

    # Get suspended currencies and remove them from list of legal currencies
    my $payout_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies($lc->short);

    return {
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
    };
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
            $trx{shortcode} = $row->{short_code};
            $trx{longcode}  = $res->{longcodes}->{$row->{short_code}} // localize('Could not retrieve contract details');
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
            currency_rate_in_total_currency =>
                convert_currency(1, $sibling->account->currency_code, $total_currency),    # This rate is used for the future stream
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
                    currency_rate_in_total_currency =>
                        convert_currency(1, $mt5_account->{currency}, $total_currency),    # This rate is used for the future stream
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

    my $client = $params->{client};

    my $status                     = $client->status->visible;
    my $id_auth_status             = $client->authentication_status;
    my $authentication_in_progress = $id_auth_status =~ /under_review|needs_action/;
    my $is_withdrawal_locked_for_fa =
        $client->status->withdrawal_locked && $client->status->withdrawal_locked->{reason} =~ /FA needs to be completed/;

    # TODO: The following variable is being added just sbecause Deriv FE needs allow_document_upload along with unwelcome status in order to enable Onfido:
    # https://github.com/binary-com/deriv-app/blob/eda89620b4ccd59198be3fc1c5da65696ad5dd57/packages/account/src/Sections/Verification/ProofOfIdentity/proof-of-identity-container.jsx#L176
    # It won't be needed if this rule is removed from the FE code.
    my $is_unwelcome_for_false_profile_info = $client->status->unwelcome && $client->locked_for_false_profile_info;

    push @$status, 'document_' . $id_auth_status if $authentication_in_progress;

    if ($client->fully_authenticated()) {
        push @$status, 'authenticated';
        # we send this status as client is already authenticated
        # so they can view upload more documents if needed
        push @$status, 'allow_document_upload';
    } elsif ($client->landing_company->is_authentication_mandatory
        or ($client->aml_risk_classification // '') eq 'high'
        or ($client->status->withdrawal_locked and not $is_withdrawal_locked_for_fa)
        or $client->status->allow_document_upload
        or $is_unwelcome_for_false_profile_info)
    {
        push @$status, 'allow_document_upload';
    }

    my $user = $client->user;

    my $provider;
    if ($user->{has_social_signup}) {
        push @$status, 'social_signup';    # differentiate between social and password based accounts
        my $user_connect = BOM::Database::Model::UserConnect->new;
        $provider = $user_connect->get_connects_by_user_id($client->user->{id})->[0];
    }

    # check whether the user need to perform financial assessment
    my $client_fa = decode_fa($client->financial_assessment());

    push(@$status, 'financial_information_not_complete') unless is_section_complete($client_fa, "financial_information");

    push(@$status, 'trading_experience_not_complete') unless is_section_complete($client_fa, "trading_experience");

    push(@$status, 'financial_assessment_not_complete') unless $client->is_financial_assessment_complete();

    push(@$status, 'trading_password_required') unless $client->user->trading_password;

    my $base_validation     = BOM::Platform::Client::CashierValidation::base_validation($client);
    my $deposit_validation  = BOM::Platform::Client::CashierValidation::deposit_validation($client);
    my $withdraw_validation = BOM::Platform::Client::CashierValidation::withdraw_validation($client);

    my @cashier_validation     = map { ($_->{status} // [])->@* } $base_validation, $deposit_validation, $withdraw_validation;
    my @cashier_missing_fields = map { ($_->{missing_fields} // [])->@* } $deposit_validation, $withdraw_validation;

    if ($base_validation->{error} or ($deposit_validation->{error} and $withdraw_validation->{error})) {
        push @$status, 'cashier_locked';
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
        has_mt5_regulated_account   => $has_mt5_regulated_account
    );
    my $authentication = _get_authentication(
        client                            => $client,
        is_document_expiry_check_required => $is_document_expiry_check_required,
        is_verification_required          => $is_verification_required,
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

    return {
        status                        => [sort(uniq(@$status))],
        risk_classification           => $client->risk_level(),
        prompt_client_to_authenticate => $is_verification_required,
        authentication                => $authentication,
        currency_config               => \%currency_config,
        @cashier_validation     ? (cashier_validation       => [sort(uniq(@cashier_validation))])     : (),
        @cashier_missing_fields ? (cashier_missing_fields   => [sort(uniq(@cashier_missing_fields))]) : (),
        $provider               ? (social_identity_provider => $provider)                             : (),
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

    my $client = $args{client};

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
    };

    return $authentication_object if $client->is_virtual;
    # Each key from the authentication object will be filled up independently by an assembler method.
    # The `needs_verification` array can be filled with `identity` and/or `document`, there is a method for each one.
    my $documents = $client->documents->uploaded();
    my $args      = {
        client    => $client,
        documents => $documents,
    };
    # Resolve the POA
    $authentication_object->{document} = _get_authentication_poa($args);
    # Resolve the POI
    $authentication_object->{identity} = _get_authentication_poi($args);
    # Current statuses
    my $poa_status = $authentication_object->{document}->{status};
    my $poi_status = $authentication_object->{identity}->{status};
    # The `needs_verification` array is built from the following hash keys
    my %needs_verification_hash;
    $needs_verification_hash{identity} = 1 if $client->needs_poi_verification($documents, $poi_status, $args{is_verification_required});
    $needs_verification_hash{document} = 1 if $client->needs_poa_verification($documents, $poa_status, $args{is_verification_required});
    # Craft the `needs_verification` array
    $authentication_object->{needs_verification} = [sort keys %needs_verification_hash];
    return $authentication_object;
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
    my $poi_expiry_date = $documents->{proof_of_identity}->{expiry_date};
    my $expiry_date     = $poi_expiry_date ? $poi_expiry_date : undef;
    my $country_code    = uc($client->place_of_birth || $client->residence // '');
    my $poi_status      = $client->get_poi_status($documents);

    my $last_rejected = [];
    push $last_rejected->@*, BOM::User::Onfido::get_consider_reasons($client)->@* if $poi_status =~ /rejected|suspected/;
    push $last_rejected->@*, BOM::User::Onfido::get_rules_reasons($client)->@*;

    my $idv = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    my $country_code_triplet = uc(Locale::Country::country_code2code($country_code, LOCALE_CODE_ALPHA_2, LOCALE_CODE_ALPHA_3) // "");

    # Return the identity structure
    return {
        status   => $poi_status,
        services => {
            onfido => {
                submissions_left     => BOM::User::Onfido::submissions_left($client),
                is_country_supported => BOM::Config::Onfido::is_country_supported($country_code),
                documents_supported  => BOM::Config::Onfido::supported_documents_for_country($country_code),
                last_rejected => [uniq map { defined $RejectedOnfidoReasons{$_} ? localize($RejectedOnfidoReasons{$_}) : () } $last_rejected->@*],
                reported_properties => BOM::User::Onfido::reported_properties($client),
                status              => $client->get_onfido_status($documents),
                $country_code_triplet ? (country_code => $country_code_triplet) : (),
            },
            idv => {
                submissions_left    => $idv->submissions_left,
                last_rejected       => $idv->get_rejected_reasons,
                reported_properties => $idv->reported_properties,
                status              => $idv->status,
            },
            manual => {
                status => $client->get_manual_poi_status($documents),
            },
        },
        defined $expiry_date ? (expiry_date => $expiry_date) : (),
    };
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
        my $brand       = request()->brand;
        my $contact_url = $brand->contact_url({
                source   => $params->{source},
                language => $params->{language}});
        _send_reset_password_confirmation_email($client, 'change_password', $brand, $contact_url);
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
        my $brand       = request()->brand;
        my $contact_url = $brand->contact_url({
                source   => $params->{source},
                language => $params->{language}});
        _send_reset_password_confirmation_email($client, 'reset_password', $brand, $contact_url);
    } catch {
        log_exception();
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordResetError',
            message_to_client => localize("We were unable to reset your password due to an unexpected error. Please try again."),
        });
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
    my ($client, $type, $brand, $contact_url) = @_;

    my $is_reset_password = $type eq 'reset_password';
    my $subject =
        $is_reset_password
        ? localize('Your password has been reset.')
        : ($brand->name eq 'deriv' ? localize('Your new Deriv account password') : localize('Your password has been changed.'));
    my $email      = $client->email;
    my $email_args = {
        to            => $email,
        subject       => $subject,
        template_name => 'reset_password_confirm',
        template_args => {
            email       => $email,
            name        => $client->first_name,
            title       => localize("You've got a new password"),
            contact_url => $contact_url
        },
        use_email_template => 1,
        template_loginid   => $client->loginid,
        use_event          => 1,
    };

    send_email($email_args);

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

    my $settings = {
        email     => $user->email,
        country   => $country,
        residence => $country
        , # Everywhere else in our responses to FE, we pass the residence key instead of country. However, we need to still pass in country for backwards compatibility.
        country_code       => $country_code,
        email_consent      => ($user and $user->{email_consent}) ? 1 : 0,
        preferred_language => $user->preferred_language,
        feature_flag       => $user->get_feature_flag,
        immutable_fields   => [$client->immutable_fields()],
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
            request_professional_status    => $client->status->professional_requested                               ? 1 : 0,
            is_authenticated_payment_agent => ($client->payment_agent and $client->payment_agent->is_authenticated) ? 1 : 0,
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
        } elsif (grep { !/$allowed_fields_for_virtual/ } keys %$args) {
            # we only allow these keys in virtual set settings any other key will result in permission error
            return BOM::RPC::v3::Utility::permission_error();
        }
    } else {
        # real client is not allowed to update residence
        return BOM::RPC::v3::Utility::permission_error() if $residence;

        my $error = $current_client->format_input_details($args);
        return BOM::RPC::v3::Utility::create_error_by_code($error->{error}) if $error;

        for my $field ($current_client->immutable_fields) {
            next unless defined($args->{$field});
            next if $args->{$field} eq $current_client->$field;

            return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => $ImmutableFieldError{$field} // localize('Permission denied.'),
            });
        }

        $error = $current_client->validate_common_account_details($args) || $current_client->check_duplicate_account($args);
        return BOM::RPC::v3::Utility::create_error_by_code($error->{error}, details => $error->{details}) if $error;
    }

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

    $user->update_preferred_language($args->{preferred_language}) if $args->{preferred_language};
    $user->set_feature_flag($args->{feature_flag})                if $args->{feature_flag};

    # email consent is per user whereas other settings are per client
    # so need to save it separately
    if (defined $args->{email_consent}) {
        $user->update_email_fields(email_consent => $args->{email_consent});
    }

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
            code              => 'TINDetailsMandatory',
            message_to_client =>
                localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')}
    ) if ($current_client->landing_company->short eq 'maltainvest' and (not $tax_residence or not $tax_identification_number));

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

    # If this is a virtual account update, we don't want to change anything else - otherwise
    # let's apply the new fields to all other accounts as well.
    my @realclient_loginids = $current_client->is_virtual ? () : $user->bom_real_loginids;

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
        $client->state($addressState)       if defined $addressState;                 # FIXME validate
        $client->postcode($addressPostcode) if defined $args->{'address_postcode'};
        $client->phone($phone)              if length $phone;
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
    BOM::Platform::Event::Emitter::emit('check_onfido_rules',  {loginid => $current_client->loginid});
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $current_client->loginid});
    BOM::Platform::Event::Emitter::emit('verify_address',      {loginid => $current_client->loginid}) if $needs_verify_address_trigger;
    $current_client->add_note('Update Address Notification', $cil_message) if $cil_message;

    # send email only if there was any changes
    if (scalar keys %$updated_fields_for_track) {
        _send_update_account_settings_email($args, $current_client, $updated_fields_for_track, $allow_copiers, $website_name, $brand);
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
    my ($args, $current_client, $updated_fields, $allow_copiers, $website_name, $brand) = @_;

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

    my $tr_tax_residence = join ', ', map { Locale::Country::code2country($_) // $_ } split /,/, ($current_client->tax_residence || '');
    my $pob_country = $current_client->place_of_birth ? Locale::Country::code2country($current_client->place_of_birth) : '';

    push @email_updated_fields,
        (
        [localize('Place of birth'), $pob_country // '', _contains_any($updated_fields, 'place_of_birth')],
        [localize("Tax residence"),  $tr_tax_residence,  _contains_any($updated_fields, 'tax_residence')],
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

    my $params;
    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    send_email({
            to      => $current_client->email,
            subject => $brand->name eq 'deriv'
            ? localize('Your new Deriv personal details')
            : $current_client->loginid . ' ' . localize('Change in account settings'),
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
                name           => $current_client->first_name,
                title          => localize('Your personal details have been updated'),
                website_name   => $website_name,
                contact_url    => $contact_url,
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
        $rule_engine->verify_action('set_self_exclusion', \%args);
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

        # the rest is applied on regulated landing companies only.
        next unless $is_regulated;

        # in regulated landing companies, clients are not allowed to extend or remove their self-exclusion settings
        if ($self_exclusion->{$field}) {
            $min = $field_settings->{is_integer} ? 1 : 0;
            return $error_sub->(localize('Please enter a number between [_1] and [_2].', $min, $self_exclusion->{$field}), $field)
                unless $value > 0 and $value <= $self_exclusion->{$field};
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

        BOM::Platform::Event::Emitter::emit('self_exclude', $data_subscription);
    }

# Need to send email in 2 circumstances:
#   - Any client sets a self exclusion period && balance > 0
#   - Client under Deriv (Europe) Limited with MT5 account(s) sets any of these settings

    my $balance;
    if ($client->default_account) {
        $balance = $client->default_account->balance;
    } else {
        $balance = '0.00';
    }

    my @mt5_logins = $client->user->mt5_logins('real');
    if ($client->landing_company->short eq 'malta' && @mt5_logins) {
        warn 'Compliance email regarding Deriv (Europe) Limited user with MT5 account(s) failed to send.'
            unless send_self_exclusion_notification($client, 'malta_with_mt5', \%args, $balance);
    } elsif ($args{exclude_until}) {
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

=item * malta_with_mt5

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
    if ($type eq 'malta_with_mt5') {
        $message = "An MT5 account holder under the Deriv (Europe) Limited landing company has set account limits.\n";
        @fields_to_email =
            qw/max_balance max_turnover max_losses max_deposit max_7day_turnover max_7day_losses max_7day_deposit max_30day_losses max_30day_turnover max_30day_deposit max_deposit_daily max_deposit_7day max_deposit_30day max_open_bets session_duration_limit exclude_until timeout_until/;
    } elsif ($type eq 'self_exclusion') {
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

        my @mt5_logins = $client->user->mt5_logins('real');
        if ($type eq 'malta_with_mt5' && @mt5_logins) {
            $message .= "\n\nClient $client_title has the following MT5 accounts:\n";
            $message .= "$_\n" for @mt5_logins;
        }

        my $to_email = $brand->emails('compliance');

        # Include accounts team if client's brokercode is MLT/MX
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
        try {
            $client->user->set_tnc_approval;
        } catch {
            log_exception();
            return BOM::RPC::v3::Utility::client_error();
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

    my $user                = $client->user;
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
        $accounts_with_balance{$client->loginid}   = {
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

    foreach my $client (@accounts_to_disable) {
        try {
            $client->status->set('disabled', $loginid, $closing_reason);
            $client->status->set('closed',   $loginid, $closing_reason);
            $loginids_disabled_success .= $client->loginid . ' ';
        } catch {
            log_exception();
            $error = BOM::RPC::v3::Utility::client_error();
            $loginids_disabled_failed .= $client->loginid . ' ';
        }
    }

    # Return error if NO loginids have been disabled
    return $error if ($error && $loginids_disabled_success eq '');

    my $data_email_consent = {
        loginid       => $loginid,
        email_consent => 0
    };

    # Remove email consents for the user (and update the clients as well)
    $user->update_email_fields(email_consent => $data_email_consent->{email_consent});

    my $data_closure = {
        closing_reason    => $closing_reason,
        loginid           => $loginid,
        loginids_disabled => $loginids_disabled_success,
        loginids_failed   => $loginids_disabled_failed,
        email_consent     => $data_email_consent->{email_consent},
    };

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
    } catch ($e) {
        log_exception();
        warn "Error caught in set_account_currency: $e\n";
    }
    return {status => $status};
};

rpc set_financial_assessment => sub {
    my $params         = shift;
    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        $rule_engine->verify_action(set_financial_assessment => $params->{args});
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

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

    # some attributes are editable exclusively from backoffice
    delete $args->{is_listed};
    delete $args->{is_authenticated};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentNotAvailable',
            message_to_client => localize('The payment agent facility is not available for this account.')}
    ) unless $client->landing_company->allows_payment_agents;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentAlreadyExists',
            message_to_client => localize("You've already submitted a payment agent application request.")}) if $client->get_payment_agent();

    # convert the array supported_payment_methods (api field) into the string supported_banks (db field)
    my $payment_methods = (delete $args->{supported_payment_methods}) // [];
    $args->{supported_banks} = join ',', @$payment_methods;

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

        if ($error->{details}->{fields}) {
            $error->{details}->{fields} = [map { $_ =~ s/supported_banks/supported_payment_methods/r } $error->{details}->{fields}->@*];
        }

        return BOM::RPC::v3::Utility::create_error_by_code($error->{code}, %$error, override_code => 'InputValidationFailed');
    }

    $pa->$_($args->{$_}) for keys %$args;
    $pa->save();

    # create a livechat ticket
    my $loginid = $client->loginid;
    my $brand   = request->brand;
    my $message = "Client $loginid has submitted the payment agent application form with following content:\n\n";
    $message .= join("\n", map { "$_: $args->{$_}" } sort keys %$args);
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('pa_livechat'),
        subject => "Payment agent application submitted by $loginid",
        message => [$message],
    });

    return {status => 1};
};

rpc paymentagent_details => sub {
    my $params = shift;
    my $client = $params->{client};

    return BOM::RPC::v3::Utility::permission_error if $client->is_virtual;

    my $payment_agent = $client->get_payment_agent;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoPaymentAgent',
            message_to_client => localize('You have not applied for being payment agent yet.')}) unless $payment_agent;

    my %result = map { $_ => $payment_agent->$_ }
        qw(payment_agent_name url email phone  information currency_code target_country max_withdrawal min_withdrawal commission_deposit commission_withdrawal is_authenticated is_listed code_of_conduct_approval affiliate_id);
    $result{supported_payment_methods} = $payment_agent->{supported_banks} ? [split(',', $payment_agent->{supported_banks})] : [];
    # affiliate IDs are null for old payment agents.
    $result{affiliate_id} //= '';

    return \%result;
};

1;

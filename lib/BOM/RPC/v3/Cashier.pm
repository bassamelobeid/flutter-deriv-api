package BOM::RPC::v3::Cashier;

use strict;
use warnings;

use HTML::Entities;
use List::Util qw( min first any);
use Scalar::Util qw( looks_like_number );
use Data::UUID;
use Path::Tiny;
use Date::Utility;
use Try::Tiny;
use String::UTF8::MD5;
use LWP::UserAgent;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use YAML::XS qw(LoadFile);
use Scope::Guard qw/guard/;
use DataDog::DogStatsd::Helper qw(stats_inc);
use Format::Util::Numbers qw/formatnumber financialrounding/;
use JSON::MaybeXS;
use Text::Trim;
use Brands;
use BOM::User qw( is_payment_agents_suspended_in_country );
use LandingCompany::Registry;
use BOM::User::Client::PaymentAgent;
use ExchangeRates::CurrencyConverter qw/convert_currency in_usd/;
use BOM::Config::CurrencyConfig;

use BOM::RPC::Registry '-dsl';

use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook get_doughflow_language_code_for );
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User::AuditLog;
use BOM::Platform::RiskProfile;
use BOM::Platform::Client::CashierValidation;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::RPC::v3::Utility;
use BOM::Transaction::Validation;
use BOM::Database::Model::HandoffToken;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::ClientDB;
requires_auth();

use constant MAX_DESCRIPTION_LENGTH => 250;

my $payment_limits = BOM::Config::payment_limits;

rpc "cashier", sub {
    my $params = shift;

    my $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, qw( compliance_checks ));
    return $validation_error if $validation_error;

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'CashierForwardError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    my ($client, $args) = @{$params}{qw/client args/};
    my $action   = $args->{cashier}  // 'deposit';
    my $provider = $args->{provider} // 'doughflow';

    # this should come before all validation as verification
    # token is mandatory for withdrawal.
    if ($action eq 'withdraw') {
        my $token = $args->{verification_code} // '';

        my $email = $client->email;
        if (not $email or $email =~ /\s+/) {
            return $error_sub->(localize("Please provide a valid email address."));
        } elsif ($token) {
            if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($token, $email, 'payment_withdraw')->{error}) {
                return BOM::RPC::v3::Utility::create_error({
                        code              => $err->{code},
                        message_to_client => $err->{message_to_client}});
            }
        } else {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'ASK_EMAIL_VERIFY',
                message_to_client => localize('Verify your withdraw request.'),
            });
        }
    } else {
        $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, qw( validate_tnc ));
        return $validation_error if $validation_error;
    }

    my $client_loginid = $client->loginid;
    my $validation = BOM::Platform::Client::CashierValidation::validate($client_loginid, $action);
    return BOM::RPC::v3::Utility::create_error({
            code              => $validation->{error}->{code},
            message_to_client => $validation->{error}->{message_to_client}}) if exists $validation->{error};

    my ($brand, $currency) = (Brands->new(name => request()->brand), $client->default_account->currency_code);

    if (LandingCompany::Registry::get_currency_type($currency) eq 'crypto') {
        return _get_cryptocurrency_cashier_url($client->loginid, $params->{website_name},
            $currency, $action, $params->{language}, $brand->name, $params->{domain});
    }

    return $error_sub->(localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if BOM::Platform::Client::CashierValidation::is_cashier_suspended();

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $client_loginid});
    # hit DF's CreateCustomer API
    my $ua = LWP::UserAgent->new(timeout => 20);
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE
    );    #temporarily disable host verification as full ssl certificate chain is not available in doughflow.

    my $doughflow_loc = BOM::Config::third_party()->{doughflow}->{$brand->name};
    my $is_white_listed = any { $params->{domain} and $params->{domain} eq $_ } BOM::Config->domain->{white_list}->@*;

    $doughflow_loc = "https://cashier.@{[ $params->{domain} ]}" if $is_white_listed;
    unless ($is_white_listed) {
        warn "Trying to access doughflow from an unrecognized domain: @{[ $params->{domain} ]}";
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.invalid_doughflow_domain.count', {tags => ["domain:@{[ $params->{domain} ]}"]});
    }

    my $doughflow_pass    = BOM::Config::third_party()->{doughflow}->{passcode};
    my $url               = $doughflow_loc . '/CreateCustomer.asp';
    my $sportsbook        = get_sportsbook($df_client->broker, $currency);
    my $handoff_token_key = _get_handoff_token_key($df_client->loginid);

    my $result = $ua->post(
        $url,
        $df_client->create_customer_property_bag({
                SecurePassCode => $doughflow_pass,
                Sportsbook     => $sportsbook,
                IP_Address     => '127.0.0.1',
                Password       => $handoff_token_key,
            }));

    if ($result->{'_content'} ne 'OK') {
        #parse error
        my $errortext = $result->{_content};

        if ($errortext =~ /custname/) {
            $client->add_note('DOUGHFLOW_ADDRESS_MISMATCH',
                      "The Doughflow server rejected the client's name.\n"
                    . "If everything is correct with the client's name, notify the development team.\n"
                    . "Loginid: $client_loginid\n"
                    . "Doughflow response: [$errortext]");

            return $error_sub->(
                localize(
                    'Sorry, there was a problem validating your personal information with our payment processor. Please check your details and try again.'
                ),
                'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
            );
        }

        if ($errortext =~ /(province|country|city|street|pcode|phone|email)/) {
            my $field = $1;

            # map to our form fields
            $field = "postcode"     if $field eq 'pcode';
            $field = "addressline1" if $field eq 'street';
            $field = "residence"    if $field eq 'country';

            return BOM::RPC::v3::Utility::create_error({
                code              => 'ASK_FIX_DETAILS',
                message_to_client => localize('There was a problem validating your personal details.'),
                details           => $field
            });
        }

        if ($errortext =~ /customer too old/) {
            $client->add_note('DOUGHFLOW_AGE_LIMIT_EXCEEDED',
                      "The Doughflow server refused to process the request due to customer age.\n"
                    . "There is currently a hardcoded limit on their system which rejects anyone over 100 years old.\n"
                    . "If the client's details have been confirmed as valid, we will need to raise this issue with\n"
                    . "the Doughflow support team.\n"
                    . "Loginid: $client_loginid\n"
                    . "Doughflow response: [$errortext]");

            return $error_sub->(
                localize(
                    'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.'
                ),
                'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
            );
        }

        warn "Unknown Doughflow error: $errortext\n";
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.doughflow_failure.count', {tags => ["action:$action"]});

        return $error_sub->(
            localize('Sorry, an error occurred. Please try accessing our cashier again.'),
            'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
        );
    }

    my $secret = String::UTF8::MD5::md5($df_client->loginid . '-' . $handoff_token_key);

    if ($action eq 'deposit') {
        $action = 'DEPOSIT';
    } elsif ($action eq 'withdraw') {
        $action = 'PAYOUT';
    }

    Path::Tiny::path('/tmp/doughflow_tokens.txt')
        ->append_utf8(join(":", Date::Utility->new()->datetime_ddmmmyy_hhmmss, $df_client->loginid, $handoff_token_key, $action));

    # build DF link
    $url =
          $doughflow_loc
        . '/login.asp?Sportsbook='
        . $sportsbook . '&PIN='
        . $df_client->loginid
        . '&Lang='
        . get_doughflow_language_code_for($params->{language})
        . '&Password='
        . $handoff_token_key
        . '&Secret='
        . $secret
        . '&Action='
        . $action;
    BOM::User::AuditLog::log('redirecting to doughflow', $df_client->loginid);
    return $url;
};

sub _get_handoff_token_key {
    my $loginid = shift;

    # create handoff token
    my $cb = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
    });

    BOM::Database::DataMapper::Payment::DoughFlow->new({
            client_loginid => $loginid,
            db             => $cb->db,
        })->delete_expired_tokens();

    my $handoff_token = BOM::Database::Model::HandoffToken->new(
        db                 => $cb->db,
        data_object_params => {
            key            => BOM::Database::Model::HandoffToken::generate_session_key,
            client_loginid => $loginid,
            expires        => time + 60,
        },
    );
    $handoff_token->save;

    return $handoff_token->key;
}

sub _get_cryptocurrency_cashier_url {
    return _get_cashier_url('cryptocurrency', @_);
}

sub _get_cashier_url {
    my ($prefix, $loginid, $website_name, $currency, $action, $language, $brand_name, $domain) = @_;

    $prefix = lc($currency) if $prefix eq 'cryptocurrency';

    BOM::User::AuditLog::log("redirecting to $prefix");

    $language = uc($language // 'EN');

    my $url = 'https://';
    if (($website_name // '') =~ /qa/) {
        $url .= 'www.' . lc($website_name) . "/cryptocurrency/$prefix";
    } else {
        my $is_white_listed = $domain && (any { $domain eq $_ } BOM::Config->domain->{white_list}->@*);
        $domain = BOM::Config->domain->{default_domain} unless $domain and $is_white_listed;
        $url .= "cryptocurrency.$domain/cryptocurrency/$prefix";
    }

    $url .=
        "/handshake?token=" . _get_handoff_token_key($loginid) . "&loginid=$loginid&currency=$currency&action=$action&l=$language&brand=$brand_name";

    return $url;
}

rpc get_limits => sub {
    my $params = shift;

    my $client = $params->{client};
    if ($client->is_virtual) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'FeatureNotAvailable',
                message_to_client => localize('Sorry, this feature is not available.')});
    }

    my $landing_company = LandingCompany::Registry->get_by_broker($client->broker)->short;
    my ($wl_config, $currency) = ($payment_limits->{withdrawal_limits}->{$landing_company}, $client->currency);

    my $limit = +{
        account_balance => formatnumber('amount', $currency, $client->get_limit_for_account_balance),
        payout          => formatnumber('price',  $currency, $client->get_limit_for_payout),
        open_positions  => $client->get_limit_for_open_positions,
    };

    my $market_specifics = BOM::Platform::RiskProfile::get_current_profile_definitions($client);
    map { $_->{name} = localize($_->{name}) } map { @$_ } values %$market_specifics;
    $limit->{market_specific} = $market_specifics;

    my $numdays               = $wl_config->{for_days};
    my $numdayslimit          = $wl_config->{limit_for_days};
    my $lifetimelimit         = $wl_config->{lifetime_limit};
    my $withdrawal_limit_curr = $wl_config->{currency};

    if ($client->fully_authenticated) {
        $numdayslimit  = 99999999;
        $lifetimelimit = 99999999;
    }

    $limit->{num_of_days} = $numdays;

    $limit->{num_of_days_limit} = formatnumber('price', $currency, convert_currency($numdayslimit,  $withdrawal_limit_curr, $currency));
    $limit->{lifetime_limit}    = formatnumber('price', $currency, convert_currency($lifetimelimit, $withdrawal_limit_curr, $currency));

    # Withdrawal since $numdays
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
    my $withdrawal_for_x_days = $payment_mapper->get_total_withdrawal({
        start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
        exclude    => ['currency_conversion_transfer'],
    });
    $withdrawal_for_x_days = convert_currency($withdrawal_for_x_days, $currency, $withdrawal_limit_curr);

    # withdrawal since inception
    my $withdrawal_since_inception =
        convert_currency($payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']}), $currency, $withdrawal_limit_curr);

    my $remainder = min(($numdayslimit - $withdrawal_for_x_days), ($lifetimelimit - $withdrawal_since_inception));
    if ($remainder < 0) {
        $remainder = 0;
    }

    $limit->{withdrawal_since_inception_monetary} =
        formatnumber('price', $currency, convert_currency($withdrawal_since_inception, $withdrawal_limit_curr, $currency));
    $limit->{withdrawal_for_x_days_monetary} =
        formatnumber('price', $currency, convert_currency($withdrawal_for_x_days, $withdrawal_limit_curr, $currency));
    $limit->{remainder} = formatnumber('price', $currency, convert_currency($remainder, $withdrawal_limit_curr, $currency));

    # also add Daily Transfer Limits
    if (defined $client->default_account) {
        my $between_accounts_transfer_limit =
            BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts;
        my $mt5_tranfer_limits = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5;

        my $client_internal_transfer = $client->get_today_transfer_summary()->{count};
        my $client_mt5_transfer      = $client->get_today_transfer_summary('mt5_transfer')->{count};

        my $available_internal_transfer = $between_accounts_transfer_limit - $client_internal_transfer;
        my $available_mt5_transfer      = $mt5_tranfer_limits - $client_mt5_transfer;

        $limit->{daily_transfers} = {
            'internal' => {
                allowed   => $between_accounts_transfer_limit,
                available => $available_internal_transfer > 0 ? $available_internal_transfer : 0,
            },
            'mt5' => {
                allowed   => $mt5_tranfer_limits,
                available => $available_mt5_transfer > 0 ? $available_mt5_transfer : 0
            }};
    }
    return $limit;
};

rpc "paymentagent_list",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my ($language, $args, $token_details) = @{$params}{qw/language args token_details/};

    my $target_country = $args->{paymentagent_list};

    my $loginid;
    my $broker_code = 'CR';
    if (ref $token_details eq 'HASH') {
        $loginid = $token_details->{loginid};
        my $client = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        });
        $broker_code = $client->broker_code if $client;
    }
    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $all_pa_countries     = $payment_agent_mapper->get_all_authenticated_payment_agent_countries();
    my @available_countries  = grep { !is_payment_agents_suspended_in_country($_->[0]) } @$all_pa_countries;

    # add country name plus code
    foreach (@available_countries) {
        $_->[1] = Brands->new(name => request()->brand)->countries_instance->countries->localized_code2country($_->[0], $language);
    }

    my $available_payment_agents = _get_available_payment_agents($target_country, $broker_code, $args->{currency}, $loginid);

    my $payment_agent_table_row = [];
    foreach my $loginid (keys %{$available_payment_agents}) {
        my $payment_agent = $available_payment_agents->{$loginid};
        my $min_max       = BOM::Config::PaymentAgent::get_transfer_min_max($payment_agent->{currency_code});

        push @{$payment_agent_table_row},
            {
            'paymentagent_loginid'  => $loginid,
            'name'                  => encode_entities($payment_agent->{payment_agent_name}),
            'summary'               => encode_entities($payment_agent->{summary}),
            'url'                   => $payment_agent->{url},
            'email'                 => $payment_agent->{email},
            'telephone'             => $payment_agent->{phone},
            'currencies'            => $payment_agent->{currency_code},
            'deposit_commission'    => $payment_agent->{commission_deposit},
            'withdrawal_commission' => $payment_agent->{commission_withdrawal},
            'further_information'   => $payment_agent->{information},
            'supported_banks'       => $payment_agent->{supported_banks},
            'max_withdrawal'        => $payment_agent->{max_withdrawal} || $min_max->{maximum},
            'min_withdrawal'        => $payment_agent->{min_withdrawal} || $min_max->{minimum},
            };
    }

    @$payment_agent_table_row = sort { lc($a->{name}) cmp lc($b->{name}) } @$payment_agent_table_row;

    return {
        available_countries => \@available_countries,
        list                => $payment_agent_table_row
    };
    };

rpc paymentagent_transfer => sub {

    my $params = shift;

    my $source    = $params->{source};
    my $client_fm = $params->{client};

    return BOM::RPC::v3::Utility::permission_error() if $client_fm->is_virtual;

    my $loginid_fm = $client_fm->loginid;

    my ($website_name, $args) = @{$params}{qw/website_name args/};
    my $currency    = $args->{currency};
    my $amount      = $args->{amount};
    my $loginid_to  = uc $args->{transfer_to};
    my $description = trim($args->{description} // '');

    my $error_sub = sub {
        my ($message_to_client) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentTransferError',
            message_to_client => $message_to_client
        });
    };

    # Simple regex plus precision check via precision.yml
    my $amount_validation_error = validate_amount($amount, $currency);
    return $error_sub->($amount_validation_error) if $amount_validation_error;

    # Check global status via the chronicle database
    my $app_config = BOM::Config::Runtime->instance->app_config;

    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents)
    {
        return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'));
    }

    # This uses the broker_code field to access landing_companies.yml
    return $error_sub->(localize('The payment agent facility is not available for this account.'))
        unless $client_fm->landing_company->allows_payment_agents;

    # Reads fiat/crypto from landing_companies.yml, then gets min/max from paymentagent_config.yml
    my $payment_agent = $client_fm->payment_agent;
    return $error_sub->(localize('You are not authorized for transfers via payment agents.')) unless $payment_agent;

    my $max_withdrawal = $payment_agent->max_withdrawal;
    my $min_withdrawal = $payment_agent->min_withdrawal;
    my $min_max        = BOM::Config::PaymentAgent::get_transfer_min_max($currency);

    return $error_sub->(localize("Invalid amount. Maximum is [_1].", $min_max->{maximum})) if ($amount > $min_max->{maximum});
    return $error_sub->(localize("Invalid amount. Maximum withdrawal allowed is [_1].", $max_withdrawal))
        if ($max_withdrawal && $amount > $max_withdrawal);

    return $error_sub->(localize('Invalid amount. Minimum is [_1].', $min_max->{minimum})) if ($amount < $min_max->{minimum});
    return $error_sub->(localize("Invalid amount. Minimum withdrawal allowed is [_1].", $min_withdrawal))
        if ($min_withdrawal && $amount < $min_withdrawal);

    my $client_to = try { BOM::User::Client->new({loginid => $loginid_to, db_operation => 'write'}) }
        or return $error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to));

    return $error_sub->(localize('Payment agent transfers are not allowed for the specified accounts.'))
        if ($client_fm->landing_company->short ne $client_to->landing_company->short);

    return $error_sub->(localize('You cannot transfer to a client in a different country of residence.'))
        if $client_fm->residence ne $client_to->residence and not _is_pa_residence_exclusion($client_fm);

    #disable/suspending pa transfers in a country, does not exclude a pa if a previous transfer is recorded in db.
    if (is_payment_agents_suspended_in_country($client_to->residence)) {
        my $available_payment_agents_for_client =
            _get_available_payment_agents($client_to->residence, $client_to->broker_code, $currency, $loginid_to);
        return $error_sub->(localize("Payment agent transfers are temporarily unavailable in the client's country of residence."))
            unless $available_payment_agents_for_client->{$client_fm->loginid};
    }

    return $error_sub->(localize('Notes must not exceed [_1] characters.', MAX_DESCRIPTION_LENGTH))
        if (length($description) > MAX_DESCRIPTION_LENGTH);

    if ($args->{dry_run}) {
        return {
            status              => 2,
            client_to_full_name => $client_to->full_name,
            client_to_loginid   => $client_to->loginid
        };
    }

    # normalized all amount to USD for comparing payment agent limits
    my ($amount_transferred_in_usd, $count) = _get_amount_and_count($loginid_fm);
    $amount_transferred_in_usd = in_usd($amount_transferred_in_usd, $currency);

    my $amount_in_usd = in_usd($amount, $currency);

    my $pa_transfer_limit = BOM::Config::payment_agent()->{transaction_limits}->{transfer};

    # maximum number of allowable transfer in usd in a day
    if (($amount_transferred_in_usd + $amount_in_usd) > $pa_transfer_limit->{amount_in_usd_per_day}) {
        return $error_sub->(
            localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transfer amount for today.'));
    }

    if ($count >= $pa_transfer_limit->{transactions_per_day}) {
        return $error_sub->(localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.'));
    }

    # execute the transfer
    my $now       = Date::Utility->new;
    my $today     = $now->datetime_ddmmmyy_hhmmss_TZ;
    my $reference = Data::UUID->new()->create_str();
    my $comment =
          'Transfer from Payment Agent '
        . $payment_agent->payment_agent_name
        . " to $loginid_to. Transaction reference: $reference. Timestamp: $today."
        . ($description ? " Agent note: $description" : '');

    ## We want to pass limits in to the function so it can verify amounts
    my $lcshort              = $client_fm->landing_company->short;
    my $lc_withdrawal_limits = BOM::Config::payment_limits()->{withdrawal_limits}->{$lcshort};
    my ($lc_lifetime_limit, $lc_for_days, $lc_limit_for_days, $lc_currency) =
        @$lc_withdrawal_limits{qw/ lifetime_limit for_days limit_for_days currency/};
    ## For some landing companies, we only check the lifetime limits. Thus, we set limit_for_days to 0:
    if ($lcshort =~ /^(?:costarica|japan|champion)$/) {
        $lc_limit_for_days = 0;
    }
    ## We also need to convert these from the landing companies currency to the current currency
    $lc_lifetime_limit = convert_currency($lc_lifetime_limit, $lc_currency, $currency);
    $lc_limit_for_days = convert_currency($lc_limit_for_days, $lc_currency, $currency);

    my ($error, $response);

    # Send email to CS whenever a new client has been deposited via payment agent
    # This assumes no deposit has been made and the following deposit is a success
    my $client_has_deposits = $client_to->has_deposits;

    try {
        # Payment agents right now cannot transfer to clients with different currencies
        # but it is not harmful to use to_amount here.
        my $to_amount = formatnumber('amount', $client_to->currency, convert_currency($amount, $currency, $client_to->currency));
        $response = $client_fm->payment_account_transfer(
            toClient           => $client_to,
            currency           => $currency,
            amount             => $amount,
            to_amount          => $to_amount,
            fmStaff            => $loginid_fm,
            toStaff            => $loginid_to,
            remark             => $comment,
            source             => $source,
            fees               => 0,
            gateway_code       => 'payment_agent_transfer',
            is_agent_to_client => 1,
            lc_lifetime_limit  => $lc_lifetime_limit,
            lc_for_days        => $lc_for_days,
            lc_limit_for_days  => $lc_limit_for_days,
        );
    }
    catch {
        chomp;
        $error = "Paymentagent Transfer failed to $loginid_to [$_]";
    };

    if ($error) {
        if ($error =~ /\bBI102 /) {
            return $error_sub->(localize('Request too frequent. Please try again later.'));
        } elsif ($error =~ /\bBI204 /) {
            return $error_sub->(localize('Payment agent transfers are not allowed within the same account.'));
        } elsif ($error =~ /\bI205 /) {    ## Redundant check (should be caught earlier by something else)
            ## Same template for two cases
            return $error_sub->(localize('Login ID ([_1]) does not exist.', $error =~ /\b$loginid_fm\b/ ? $loginid_fm : $loginid_to));
        } elsif ($error =~ /\bBI206 /) {    ## Redundant check (account is virtual)
            return $error_sub->(localize('Sorry, this feature is not available.'), $error);
        } elsif ($error =~ /\bBI207 /) {
            return $error_sub->(localize('Your cashier is locked as per your request.'), $error);
        } elsif ($error =~ /\bBI208 /) {
            return $error_sub->(localize('You cannot transfer to account [_1], as their cashier is locked.', $loginid_to));
        } elsif ($error =~ /\bBI209 /) {
            return $error_sub->(localize('You cannot perform this action, as your account is cashier locked.'));
        } elsif ($error =~ /\bBI210 /) {
            return $error_sub->(localize('You cannot perform this action, as your account is currently disabled.'));
        } elsif ($error =~ /\bBI211 /) {
            return $error_sub->(localize('Withdrawal is disabled.'));
        } elsif ($error =~ /\bBI212 /) {
            return $error_sub->(localize('You cannot transfer to account [_1], as their account is currently disabled.', $loginid_to));
        } elsif ($error =~ /\bBI213 /) {
            return $error_sub->(localize('You cannot transfer to account [_1], as their account is marked as unwelcome.', $loginid_to));
        } elsif ($error =~ /\bBI214 /) {
            return $error_sub->(localize('You cannot perform this action, as your verification documents have expired.'));
        } elsif ($error =~ /\bBI215 /) {
            return $error_sub->(localize('You cannot transfer to account [_1], as their verification documents have expired.', $loginid_to));
        } elsif ($error =~ /\bBI216 /) {    ## Redundant check
            return $error_sub->(localize('You are not authorized for transfers via payment agents.'));
        } elsif ($error =~ /\bBI217 /) {
            return $error_sub->(localize('Your account needs to be authenticated to perform payment agent transfers.'));
        } elsif ($error =~ /\bBI218 /) {
            return $error_sub->(
                localize(
                    'You cannot perform this action, as [_1] is not the default account currency for payment agent [_2].', $currency,
                    $payment_agent->client_loginid
                ));
        } elsif ($error =~ /\bBI219 /) {
            return $error_sub->(
                localize('You cannot perform this action, as [_1] is not the default account currency for client [_2].', $currency, $loginid_fm));
        } elsif ($error =~ /\bBI220 /) {
            return $error_sub->(
                localize('You cannot perform this action, as [_1] is not the default account currency for client [_2].', $currency, $loginid_to));
        } elsif ($error =~ /\bBI221 /) {
            ## We cannot derive the values easily, so we get from the database
            $error = $1 if $error =~ /ERROR:  (.+)/;
            my $datadump = decode_json($error);
            return $error_sub->(
                localize(
                    'Withdrawal is [_1] [_2] but balance [_3] includes frozen bonus [_4].',
                    $currency, $datadump->{amount}, $datadump->{balance}, $datadump->{bonus}));
        } elsif ($error =~ /\bBI222 /) {
            $error = $1 if $error =~ /ERROR:  (.+)/;
            my $datadump = decode_json($error);

            # lock cashier and unwelcome if its MX (as per compliance, check with compliance if you want to remove it)
            if ($lcshort eq 'iom') {
                $client_fm->status->set('cashier_locked', 'system', 'Exceeds withdrawal limit');
                $client_fm->status->set('unwelcome',      'system', 'Exceeds withdrawal limit');
            }

            ## If the amount left is non-negative, we show exactly how much at the end of the message
            return $error_sub->(
                localize(
                    'Sorry, you cannot withdraw. Your withdrawal amount [_1] exceeds withdrawal limit[_2].',
                    "$currency $datadump->{amount}",
                    $datadump->{limit_left} <= 0 ? '' : " $currency $datadump->{limit_left}"
                ));
        } elsif ($error =~ /\bBI223 /) {
            $error = $1 if $error =~ /ERROR:  (.+)/;
            my $datadump = decode_json($error);

            return $error_sub->(localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $currency, $datadump->{balance}));
        } else {
            return $error_sub->(localize("Sorry, an error occurred whilst processing your request."));
        }
    }

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'payment_agent',
        currency      => $currency,
        loginid       => $loginid_to,
        type          => 'deposit',
        amount        => $amount,
        payment_agent => 0,
    );

    $client_to->send_new_client_email() unless $client_has_deposits;

    # sent email notification to client
    my $emailcontent = localize(
        'Dear [_1] [_2] [_3],',                  encode_entities($client_to->salutation),
        encode_entities($client_to->first_name), encode_entities($client_to->last_name))
        . "\n\n"
        . localize(
        'We would like to inform you that the transfer of [_1] [_2] via [_3] has been processed.
The funds have been credited into your account.

Kind Regards,

The [_4] team.', $currency, $amount, encode_entities($payment_agent->payment_agent_name), $website_name
        );

    send_email({
        'from'                  => Brands->new(name => request()->brand)->emails('support'),
        'to'                    => $client_to->email,
        'subject'               => localize('Acknowledgement of Money Transfer'),
        'message'               => [$emailcontent],
        'use_email_template'    => 1,
        'email_content_is_html' => 1,
        'template_loginid'      => $loginid_to
    });

    return {
        status              => 1,
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to,
        transaction_id      => $response->{transaction_id}};
};

=head2 _get_available_payment_agents

	my $available_agents = _get_available_payment_agents('id', 'CR', 'USD', 'CR90000');

Returns a hash reference containing authenticated payment agents available for the input search criteria.

It gets the following args:

=over 4

=item * country

=item * broker_code

=item * currency (optional)

=item * client_loginid (optional), it is used for retrieving payment agents with previous transfer/withdrawal with a C<client> when the feature is suspended in the C<country> of residence.

=back

=cut

sub _get_available_payment_agents {
    my ($country, $broker_code, $currency, $loginid) = @_;
    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $authenticated_paymentagent_agents = BOM::User::Client::PaymentAgent->get_payment_agents($country, $broker_code, $currency);

    #if payment agents are suspended in client's country, we will keep only those agents that the client has previously transfered money with.
    if (is_payment_agents_suspended_in_country($country)) {
        my $linked_pas = $payment_agent_mapper->get_payment_agents_linked_to_client($loginid);
        my %linked_agents = $loginid ? (map { $_->[0] => 1 } @$linked_pas) : ();
        foreach my $key (keys %$authenticated_paymentagent_agents) {
            #TODO: The condition ($key eq $loginid) is included to prevent returning
            #an empty payemntagent_list, because our FE reads currently logged-in
            #agent's settings (like min/max transfer limit) from this list. Better to
            #remove it after moving pa settings into a new section in 'get_settings' API call.
            delete $authenticated_paymentagent_agents->{$key} unless $linked_agents{$key} or $loginid and ($key eq $loginid);
        }
    }
    return $authenticated_paymentagent_agents;
}

sub _is_pa_residence_exclusion {
    my $client               = shift;
    my $residence_exclusions = BOM::Config::Runtime->instance->app_config->payments->payment_agent_residence_check_exclusion;
    return ($client && (grep { $_ eq $client->email } @$residence_exclusions)) ? 1 : 0;
}

rpc paymentagent_withdraw => sub {
    my $params = shift;

    my $source = $params->{source};
    my $client = $params->{client};

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    my ($website_name, $args) = @{$params}{qw/website_name args/};

    # expire token only when its not dry run
    unless ($args->{dry_run}) {
        my $err =
            BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $client->email, 'paymentagent_withdraw')->{error};
        if ($err) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => $err->{code},
                    message_to_client => $err->{message_to_client}});
        }
    }

    my $currency             = $args->{currency};
    my $amount               = $args->{amount};
    my $further_instruction  = trim($args->{description} // '');
    my $paymentagent_loginid = $args->{paymentagent_loginid};
    my $reference            = Data::UUID->new()->create_str();

    my $client_loginid = $client->loginid;
    my $error_sub      = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentWithdrawError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    # 2018/05/04: Currently this check is irrelevent, because only CR clients can use payment agents, and they
    #   aren't required to accept T&Cs. It's here in case either of these situations change.
    return $error_sub->(localize('Terms and conditions approval is required.')) if $client->is_tnc_approval_required;

    my $amount_validation_error = validate_amount($amount, $currency);
    return $error_sub->($amount_validation_error) if $amount_validation_error;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents)
    {
        return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'));
    }

    return $error_sub->(localize('Payment agent facilities are not available for this account.'))
        unless $client->landing_company->allows_payment_agents;

    return $error_sub->(localize('You are not authorized for withdrawals via payment agents.'))
        unless (BOM::Transaction::Validation->new({clients => [$client]})->allow_paymentagent_withdrawal($client));

    return $error_sub->(localize('Your cashier is locked as per your request.')) if $client->cashier_setting_password;

    return $error_sub->(localize('You cannot withdraw funds to the same account.')) if $client_loginid eq $paymentagent_loginid;

    my $authenticated_pa;
    if ($client->residence) {
        my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $client->broker});
        $authenticated_pa = $payment_agent_mapper->get_authenticated_payment_agents({target_country => $client->residence});
    }

    return $error_sub->(localize('The payment agent facility is currently not available in your country.'))
        if (not $client->residence or scalar keys %{$authenticated_pa} == 0);

    return $error_sub->(localize('You cannot perform this action, as your account is currently disabled.')) if $client->status->disabled;

    my $paymentagent = BOM::User::Client::PaymentAgent->new({
            'loginid'    => $paymentagent_loginid,
            db_operation => 'replica'
        }) or return $error_sub->(localize('The payment agent account does not exist.'));

    return $error_sub->(localize('Payment agent withdrawals are not allowed for specified accounts.')) if ($client->broker ne $paymentagent->broker);

    my $pa_client = $paymentagent->client;
    return $error_sub->(
        localize('You cannot perform this action, as [_1] is not default currency for your account [_2].', $currency, $client->loginid))
        if ($client->currency ne $currency or not $client->default_account);

    return $error_sub->(
        localize("You cannot perform this action, as [_1] is not default currency for payment agent account [_2].", $currency, $pa_client->loginid))
        if ($pa_client->currency ne $currency or not $pa_client->default_account);

    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);

    return $error_sub->(localize('Invalid amount. Minimum is [_1], maximum is [_2].', $min_max->{minimum}, $min_max->{maximum}))
        if ($amount < $min_max->{minimum} || $amount > $min_max->{maximum});

    # check that the additional information does not exceeded the allowed limits
    return $error_sub->(localize('Further instructions must not exceed [_1] characters.', MAX_DESCRIPTION_LENGTH))
        if (length($further_instruction) > MAX_DESCRIPTION_LENGTH);

    # check that both the client payment agent cashier is not locked
    return $error_sub->(localize('You cannot perform this action, as your account is cashier locked.')) if $client->status->cashier_locked;

    return $error_sub->(localize('You cannot perform this action, as your account is withdrawal locked.'))
        if $client->status->withdrawal_locked;

    return $error_sub->(localize('You cannot perform this action, as your verification documents have expired.')) if $client->documents_expired;

    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is disabled.", $pa_client->loginid))
        if $pa_client->status->disabled;

    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is marked as unwelcome.", $pa_client->loginid))
        if $pa_client->status->unwelcome;

    return $error_sub->(localize("You cannot perform the withdrawal to account [_1], as the payment agent's cashier is locked.", $pa_client->loginid))
        if ($pa_client->status->cashier_locked or $pa_client->cashier_setting_password);

    return $error_sub->(
        localize("You cannot perform withdrawal to account [_1], as payment agent's verification documents have expired.", $pa_client->loginid))
        if $pa_client->documents_expired;

    return $error_sub->(localize('You cannot withdraw from a payment agent in a different country of residence.'))
        if $client->residence ne $pa_client->residence and not _is_pa_residence_exclusion($pa_client);

    if (is_payment_agents_suspended_in_country($client->residence)) {
        my $available_payment_agents_for_client =
            _get_available_payment_agents($client->residence, $client->broker_code, $currency, $client->loginid);
        return $error_sub->(localize("Payment agent transfers are temporarily unavailable in the client's country of residence."))
            unless $available_payment_agents_for_client->{$pa_client->loginid};
    }

    if ($args->{dry_run}) {
        return {
            status            => 2,
            paymentagent_name => $paymentagent->payment_agent_name
        };
    }

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $client_loginid,
    });

    my $paymentagent_client_db = BOM::Database::ClientDB->new({
        client_loginid => $paymentagent_loginid,
    });

    my $guard_scope = guard {
        $client_db->unfreeze;
        $paymentagent_client_db->unfreeze;
    };

    # freeze loginID to avoid a race condition
    return $error_sub->(
        localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
        "Account stuck in previous transaction $client_loginid"
    ) unless $client_db->freeze;

    return $error_sub->(
        localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
        "Account stuck in previous transaction $paymentagent_loginid"
    ) unless $paymentagent_client_db->freeze;

    my $withdraw_error;
    try {
        $client->validate_payment(
            currency => $currency,
            amount   => -$amount,    #withdraw action use negative amount
        );
    }
    catch {
        $withdraw_error = $_;
    };

    if ($withdraw_error) {
        return $error_sub->(
            __client_withdrawal_notes({
                    client => $client,
                    amount => $amount,
                    error  => $withdraw_error
                }));
    }

    my $day = Date::Utility->new->is_a_weekend ? 'weekend' : 'weekday';
    my $withdrawal_limit = BOM::Config::payment_agent()->{transaction_limits}->{withdraw};

    my ($amount_transferred_in_usd, $count) = _get_amount_and_count($client_loginid);
    $amount_transferred_in_usd = in_usd($amount_transferred_in_usd, $currency);

    my $amount_in_usd = in_usd($amount, $currency);

    my $daily_limit = $withdrawal_limit->{$day}->{amount_in_usd_per_day};

    if (($amount_transferred_in_usd + $amount_in_usd) > $daily_limit) {
        return $error_sub->(
            localize(
                'Sorry, you have exceeded the maximum allowable transfer amount [_1] for today.',
                $currency . formatnumber('price', $currency, convert_currency($daily_limit, 'USD', $currency))));
    }

    if ($count >= $withdrawal_limit->{$day}->{transactions_per_day}) {
        return $error_sub->(localize('Sorry, you have exceeded the maximum allowable transactions for today.'));
    }

    my $comment =
          'Transfer from '
        . $client_loginid
        . ' to Payment Agent '
        . $paymentagent->payment_agent_name
        . ' Transaction reference: '
        . $reference
        . ' Timestamp: '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;

    $comment .= ". Client note: $further_instruction" if ($further_instruction);

    my ($error, $response);
    try {
        # execute the transfer.
        $response = $client->payment_account_transfer(
            currency           => $currency,
            amount             => $amount,
            remark             => $comment,
            fmStaff            => $client_loginid,
            toStaff            => $paymentagent_loginid,
            toClient           => $pa_client,
            source             => $source,
            fees               => 0,
            is_agent_to_client => 0,
            gateway_code       => 'payment_agent_transfer',
        );
    }
    catch {
        $error = "Paymentagent Withdraw failed to $paymentagent_loginid [$_]";
    };

    if ($error) {
        # too many attempts
        if ($error =~ /\bBI102 /) {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $error);
        } else {
            warn "Error in paymentagent_transfer for withdrawal - $error\n";
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'), $error);
        }
    }

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'payment_agent',
        currency      => $currency,
        loginid       => $pa_client->loginid,
        type          => 'withdrawal',
        amount        => $amount,
        payment_agent => 0,
    );

    my $client_name = $client->first_name . ' ' . $client->last_name;
    # sent email notification to Payment Agent
    my $emailcontent = [
        localize(
            'Dear [_1] [_2] [_3],',                  encode_entities($pa_client->salutation),
            encode_entities($pa_client->first_name), encode_entities($pa_client->last_name)
        ),
        '',
        localize(
            'We would like to inform you that the withdrawal request of [_1][_2] by [_3] [_4] has been processed. The funds have been credited into your account [_5] at [_6].',
            $currency,
            $amount,
            encode_entities($client_name),
            $client_loginid,
            $paymentagent_loginid,
            $website_name
        ),
        '',
        $further_instruction,
        '',
        localize('Kind Regards,'),
        '',
        localize('The [_1] team.', $website_name),
    ];

    send_email({
        from                  => Brands->new(name => request()->brand)->emails('support'),
        to                    => $paymentagent->email,
        subject               => localize('Acknowledgement of Withdrawal Request'),
        message               => $emailcontent,
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => $pa_client->loginid,
    });

    return {
        status            => 1,
        paymentagent_name => $paymentagent->payment_agent_name,
        transaction_id    => $response->{transaction_id}};
};

sub __client_withdrawal_notes {
    my $arg_ref  = shift;
    my $client   = $arg_ref->{'client'};
    my $currency = $client->currency;
    my $amount   = formatnumber('amount', $currency, $arg_ref->{'amount'});
    my $error    = $arg_ref->{'error'};
    my $balance  = $client->default_account ? formatnumber('amount', $currency, $client->default_account->balance) : 0;

    if ($error =~ /exceeds client balance/) {
        return (localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $currency, $balance));
    } elsif ($error =~ /exceeds withdrawal limit \[(.+)\]/) {
        # if limit <= 0, we show: Your withdrawal amount USD 100.00 exceeds withdrawal limit.
        # if limit > 0, we show: Your withdrawal amount USD 100.00 exceeds withdrawal limit USD 20.00.
        my $limit = " $1";
        if ($limit =~ /\s+0\.00$/ or $limit =~ /\s+-\d+\.\d+$/) {
            $limit = '';
        }

        return (localize('Sorry, you cannot withdraw. Your withdrawal amount [_1] exceeds withdrawal limit[_2].', "$currency $amount", $limit));
    }

    my $withdrawal_limits = $client->get_withdrawal_limits();

    # At this point, the Client is not allowed to withdraw. Return error message.
    my $error_message = $error;

    if ($withdrawal_limits->{'frozen_free_gift'} > 0) {
        # Insert turnover limit as a parameter depends on the promocode type
        $error_message .= ' '
            . localize(
            'Note: You will be able to withdraw your bonus of [_1][_2] only once your aggregate volume of trades exceeds [_1][_3]. This restriction applies only to the bonus and profits derived therefrom.  All other deposits and profits derived therefrom can be withdrawn at any time.',
            $currency,
            $withdrawal_limits->{'frozen_free_gift'},
            $withdrawal_limits->{'free_gift_turnover_limit'});
    }

    return ($error_message);
}

=head2 get_transfer_fee_remark

Returns a description for the fee applied to a transfer. This function is created to make the code fragment reusable between cashier and MT5.
Takes the following list of arguments:

=over 4

=item fees: actual amount of fee to be applied.

=item fee_percent: the fee percentage used for the current transfer.

=item currency: currency of the sending account.

=item min_fee: the smallest amount meaningful in the sending currency.

=item fee_calculated_by_percent: the fee amount calculated directly by applying the fee percent alone.

=back 

Returns a string in one of the following forms:

=over 4

=item '': when fees = 0

=item 'Includes transfer fee of USD 10 (0.5 %).': when fees >= min_fee

=item 'Includes minimim transfer fee of USD 0.01.': when fees < min_fee

=back

=cut

sub get_transfer_fee_remark {
    my (%args) = @_;

    return '' unless $args{fees};

    return "Includes transfer fee of $args{currency} "
        . formatnumber(
        amount => $args{currency},
        $args{fee_calculated_by_percent})
        . " ($args{fee_percent}%)."
        if $args{fee_calculated_by_percent} >= $args{minimum_fee};

    return "Includes the minimum transfer fee of $args{currency} $args{minimum_fee}.";
}

rpc transfer_between_accounts => sub {
    my $params = shift;
    my $err;

    my ($client, $source) = @{$params}{qw/client source/};

    if (BOM::Platform::Client::CashierValidation::is_payment_suspended()) {
        return _transfer_between_accounts_error(localize('Payments are suspended.'));
    }

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is currently disabled.'))
        if $client->status->disabled;
    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is cashier locked.'))
        if $client->status->cashier_locked;

    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is withdrawal locked.'))
        if $client->status->withdrawal_locked;
    return _transfer_between_accounts_error(localize('Your cashier is locked as per your request.')) if $client->cashier_setting_password;

    my $args = $params->{args};
    my ($currency, $amount) = @{$args}{qw/currency amount/};

    my $siblings = $client->real_account_siblings_information(include_disabled => 0);
    unless (keys %$siblings) {
        warn __PACKAGE__ . "::transfer_between_accounts Error:  Unable to get user data for " . $client->loginid . "\n";
        return _transfer_between_accounts_error(localize('Internal server error'));
    }

    my ($loginid_from, $loginid_to) = @{$args}{qw/account_from account_to/};

    my @accounts;
    foreach my $cl (values %$siblings) {
        push @accounts,
            {
            loginid  => $cl->{loginid},
            balance  => $cl->{balance},
            currency => $cl->{currency},
            };
    }

    # get clients if loginid from or to is not provided
    if (not $loginid_from or not $loginid_to) {
        return {
            status   => 0,
            accounts => \@accounts
        };
    }

    return _transfer_between_accounts_error(localize('Please provide valid currency.')) unless $currency;
    return _transfer_between_accounts_error(localize('Please provide valid amount.'))
        if (not looks_like_number($amount) or $amount <= 0);
    # create client from siblings so that we are sure that from and to loginid
    # provided are for same user
    my ($client_from, $client_to, $res);
    try {

        $client_from = BOM::User::Client->new({loginid => $siblings->{$loginid_from}->{loginid}});
        $client_to   = BOM::User::Client->new({loginid => $siblings->{$loginid_to}->{loginid}});
    }
    catch {
        $res = _transfer_between_accounts_error();
    };
    return $res if $res;

    my ($from_currency, $to_currency) =
        ($siblings->{$client_from->loginid}->{currency}, $siblings->{$client_to->loginid}->{currency});
    $res = _validate_transfer_between_accounts(
        $client,
        $client_from,
        $client_to,
        {
            currency      => $currency,
            amount        => $amount,
            from_currency => $from_currency,
            to_currency   => $to_currency,
        });
    return $res if $res;

    BOM::User::AuditLog::log("Account Transfer ATTEMPT, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);
    my $error_audit_sub = sub {
        my ($err, $client_message) = @_;
        BOM::User::AuditLog::log("Account Transfer FAILED, $err");
        $client_message ||= localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.' . $err);
        return _transfer_between_accounts_error($client_message);
    };

    my ($to_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent);
    try {
        ($to_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $from_currency, $to_currency, $client_from, $client_to);
    }
    catch {
        $err = $_;
    };

    if ($err) {
        return $error_audit_sub->($err, localize('Sorry, transfers are currently unavailable. Please try again later.'))
            if ($err =~ /No rate available to convert/);

        return $error_audit_sub->($err, localize('Account transfers are not possible between [_1] and [_2].', $from_currency, $to_currency))
            if ($err =~ /No transfer fee/);

        # Lower than min_unit in the receiving currency. The lower-bounds are not uptodate, otherwise we should not accept the amount in sending currency.
        # To update them, transfer_between_accounts_fees is called again with force_refresh on.
        return $error_audit_sub->(
            $err,
            localize(
                "This amount is too low. Please enter a minimum of [_1] [_2].",
                BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{$from_currency}->{min},
                $from_currency
            )) if ($err =~ /The amount .* is below the minimum allowed amount .* for $to_currency/);

        return $error_audit_sub->($err);
    }

    my $fm_client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid_from,
    });
    my $to_client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid_to,
    });

    # have added this as exception in unused var test
    my $guard_scope = guard {
        $fm_client_db->unfreeze;
        $to_client_db->unfreeze;
    };

    my $err_msg = "from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount], ";
    if (not $fm_client_db->freeze) {
        return $error_audit_sub->("$err_msg error[Account stuck in previous transaction " . $loginid_from . ']');
    }
    if (not $to_client_db->freeze) {
        return $error_audit_sub->("$err_msg error[Account stuck in previous transaction " . $loginid_to . ']');
    }

    try {
        $client_from->validate_payment(
            currency => $currency,
            amount   => -1 * $amount,
        ) || die "validate_payment [$loginid_from]";
    }
    catch {
        $err = $_;
    };

    if ($err) {
        my $limit;
        if ($err =~ /exceeds client balance/) {
            $limit = $currency . ' ' . formatnumber('amount', $currency, $client_from->default_account->balance);
        } elsif ($err =~ /includes frozen bonus \[(.+)\]/) {
            my $frozen_bonus = $1;
            $limit = $currency . ' ' . formatnumber('amount', $currency, $client_from->default_account->balance - $frozen_bonus);
        } elsif ($err =~ /exceeds withdrawal limit \[(.+)\](?:\s+\((.+)\))?/) {
            my $bal_1 = $1;
            my $bal_2 = $2;
            $limit = $bal_1;

            if ($bal_1 =~ /^([A-Z]{3})\s+/ and $1 ne $currency) {
                $limit .= " ($bal_2)";
            }
        }

        return $error_audit_sub->(
            "$err_msg validate_payment failed for $loginid_from [$err]",
            (defined $limit) ? localize("The maximum amount you may transfer is: [_1].", $limit) : ''
        );
    }

    try {
        $client_to->validate_payment(
            currency => $to_currency,
            amount   => $to_amount,
        ) || die "validate_payment [$loginid_to]";
    }
    catch {
        $err = $_;
    };
    if ($err) {
        my $msg = localize("Transfer validation failed on [_1].", $loginid_to);
        if ($err =~ /Balance would exceed ([\S]+) limit/) {
            $msg = localize("Your account balance will exceed set limits. Please specify a lower amount.");
        }
        return $error_audit_sub->("$err_msg validate_payment failed for $loginid_to [$err]", $msg);
    }
    my $response;
    try {
        my $remark            = "Account transfer from $loginid_from to $loginid_to.";
        my $additional_remark = get_transfer_fee_remark(
            fees                      => $fees,
            fee_percent               => $fees_percent,
            currency                  => $currency,
            minimum_fee               => $min_fee,
            fee_calculated_by_percent => $fee_calculated_by_percent
        );

        $remark = "$remark $additional_remark" if $additional_remark;

        $response = $client_from->payment_account_transfer(
            currency          => $currency,
            amount            => $amount,
            to_amount         => $to_amount,
            toClient          => $client_to,
            fmStaff           => $loginid_from,
            toStaff           => $loginid_to,
            remark            => $remark,
            inter_db_transfer => ($client_from->landing_company->short ne $client_to->landing_company->short),
            source            => $source,
            fees              => $fees,
            gateway_code      => 'account_transfer',
        );
    }
    catch {
        $err = "$err_msg Account Transfer failed [$_]";
    };
    if ($err) {
        return $error_audit_sub->($err);
    }
    BOM::User::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    return {
        status              => 1,
        transaction_id      => $response->{transaction_id},
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to
    };
};

rpc topup_virtual => sub {
    my $params = shift;

    my ($client, $source) = @{$params}{qw/client source/};

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'TopupVirtualError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    # ERROR CHECKS
    if (!$client->is_virtual) {
        return $error_sub->(localize('Sorry, this feature is available to virtual accounts only'));
    }

    my $currency              = $client->default_account->currency_code;
    my $min_topup_bal         = BOM::Config::payment_agent()->{minimum_topup_balance};
    my $minimum_topup_balance = $min_topup_bal->{$currency} // $min_topup_bal->{DEFAULT};

    if ($client->default_account->balance > $minimum_topup_balance) {
        return $error_sub->(
            localize(
                'You can only request additional funds if your virtual account balance falls below [_1] [_2].',
                $currency, formatnumber('amount', $currency, $minimum_topup_balance)));
    }

    # CREDIT HIM WITH THE MONEY
    my ($curr, $amount) = $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

    return {
        amount   => $amount,
        currency => $curr
    };
};

sub _get_amount_and_count {
    my $loginid  = shift;
    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
        operation      => 'replica',
    });
    my $amount_data = $clientdb->getall_arrayref('select * from payment_v1.get_today_payment_agent_withdrawal_sum_count(?)', [$loginid]);
    return ($amount_data->[0]->{amount}, $amount_data->[0]->{count});
}

sub _transfer_between_accounts_error {
    my ($message_to_client, $message) = @_;
    return BOM::RPC::v3::Utility::create_error({
        code              => 'TransferBetweenAccountsError',
        message_to_client => ($message_to_client // localize('Transfers between accounts are not available for your account.')),
        ($message) ? (message => $message) : (),
    });
}

sub _validate_transfer_between_accounts {
    my ($current_client, $client_from, $client_to, $args) = @_;

    # error out if one of the client is not defined, i.e.
    # loginid provided is wrong or not in siblings
    return _transfer_between_accounts_error() if (not $client_from or not $client_to);

    return BOM::RPC::v3::Utility::permission_error() if ($client_from->is_virtual or $client_to->is_virtual);

    # error out if from and to loginid are same
    return _transfer_between_accounts_error(localize('Account transfers are not available within same account.'))
        unless ($client_from->loginid ne $client_to->loginid);

    # error out if current logged in client and loginid from passed are not same
    return _transfer_between_accounts_error(localize('From account provided should be same as current authorized client.'))
        unless ($current_client->loginid eq $client_from->loginid);

    my ($currency, $amount, $from_currency, $to_currency) = @{$args}{qw/currency amount from_currency to_currency/};

    my $from_currency_type = LandingCompany::Registry::get_currency_type($currency);
    return _transfer_between_accounts_error(localize('Please provide valid currency.')) unless $from_currency_type;

    my ($lc_from, $lc_to) = ($client_from->landing_company, $client_to->landing_company);

    # error if landing companies are different with exception
    # of maltainvest and malta as we allow transfer between them
    return _transfer_between_accounts_error()
        if (($lc_from->short ne $lc_to->short)
        and ($lc_from->short !~ /^(?:malta|maltainvest)$/ or $lc_to->short !~ /^(?:malta|maltainvest)$/));

# error if currency is not legal for landing company
    return _transfer_between_accounts_error(localize('Currency provided is not valid for your account.'))
        if (not $lc_from->is_currency_legal($currency) or not $lc_to->is_currency_legal($currency));

    return _transfer_between_accounts_error(
        localize('You cannot perform this action, as your account [_1] is currently disabled.', $client_to->loginid))
        if $client_to->status->disabled;

    return _transfer_between_accounts_error(
        localize('You cannot perform this action, as your account [_1] is marked as unwelcome.', $client_to->loginid))
        if $client_to->status->unwelcome;

    return _transfer_between_accounts_error(
        localize('Your cannot perform this action, as your account [_1] cashier is locked as per request.', $client_to->loginid))
        if $client_to->cashier_setting_password;

    # error out if from account has no currency set
    return _transfer_between_accounts_error(localize('Please deposit to your account.')) unless $from_currency;

    # error if currency provided is not same as from account default currency
    return _transfer_between_accounts_error(localize('Currency provided is different from account currency.'))
        if ($from_currency ne $currency);

    # error out if to account has no currency set, we should
    # not set it from currency else client will be able to
    # set same crypto for multiple account
    return _transfer_between_accounts_error(localize('Please set the currency for your existing account [_1].', $client_to->loginid))
        unless $to_currency;

    return _transfer_between_accounts_error(localize('Your [_1] cashier is locked as per your request.', $client_to->loginid))
        if $client_to->cashier_setting_password;

    my $min_allowed_amount = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{min};

    return _transfer_between_accounts_error(
        localize('This amount is too low. Please enter a minimum of [_1] [_2].', formatnumber('amount', $currency, $min_allowed_amount), $currency))
        if $amount < $min_allowed_amount;

    my $err = validate_amount($amount, $currency);
    return _transfer_between_accounts_error($err) if $err;

    my $to_currency_type = LandingCompany::Registry::get_currency_type($to_currency);

    # we don't allow fiat to fiat if they are different currency
    # this only happens when there is an internal transfer between MLT to MF, we only allow same currency transfer
    return _transfer_between_accounts_error(localize('Account transfers are not available for accounts with different currencies.'))
        if (($from_currency_type eq $to_currency_type) and ($from_currency_type eq 'fiat') and ($currency ne $to_currency));

    return _transfer_between_accounts_error(localize('Transfers between fiat and crypto accounts are currently disabled.'))
        if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
        and (($from_currency_type // '') ne ($to_currency_type // ''));

    # we don't allow crypto to crypto transfer
    return _transfer_between_accounts_error(localize('Account transfers are not available within accounts with cryptocurrency as default currency.'))
        if (($from_currency_type eq $to_currency_type) and ($from_currency_type eq 'crypto'));

    # we don't allow transfer between these two currencies
    if ($from_currency ne $to_currency) {
        my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;
        return _transfer_between_accounts_error(localize('Account transfers are not available between [_1] and [_2].', $from_currency, $to_currency))
            if first { $_ eq $from_currency or $_ eq $to_currency } @$disabled_for_transfer_currencies;
    }

    # check for internal transactions number limits
    my $daily_transfer_limit  = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts;
    my $client_today_transfer = $current_client->get_today_transfer_summary();
    return _transfer_between_accounts_error(localize("Maximum of [_1] transfers allowed per day.", $daily_transfer_limit))
        unless $client_today_transfer->{count} < $daily_transfer_limit;

    return undef;
}

sub validate_amount {
    my ($amount, $currency) = @_;

    return localize('Invalid amount.') if ($amount !~ m/^(?:\d+\.?\d*|\.\d+)$/);

    my $num_of_decimals = Format::Util::Numbers::get_precision_config()->{amount}->{$currency};
    return localize('Invalid currency.') unless defined $num_of_decimals;

    my ($precision) = $amount =~ /\.(\d+)/;
    return localize('Invalid amount. Amount provided can not have more than [_1] decimal places.', $num_of_decimals)
        if (defined $precision and length($precision) > $num_of_decimals);

    return undef;
}

1;

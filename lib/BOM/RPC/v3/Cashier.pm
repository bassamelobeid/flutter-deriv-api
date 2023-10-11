package BOM::RPC::v3::Cashier;

use strict;
use warnings;

use HTML::Entities;
use List::Util   qw( min first any );
use Scalar::Util qw( looks_like_number );
use Data::UUID;
use Path::Tiny;
use Date::Utility;
use Syntax::Keyword::Try;
use String::UTF8::MD5;
use LWP::UserAgent;
use HTTP::Headers;
use Log::Any                   qw($log);
use IO::Socket::SSL            qw( SSL_VERIFY_NONE );
use YAML::XS                   qw(LoadFile);
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use Format::Util::Numbers      qw/formatnumber financialrounding/;
use JSON::MaybeXS;
use Text::Trim;
use Math::BigFloat;

use BOM::User qw( is_payment_agents_suspended_in_country );
use LandingCompany::Registry;
use BOM::User::Client::PaymentAgent;
use ExchangeRates::CurrencyConverter qw/convert_currency in_usd offer_to_clients/;
use BOM::Config::CurrencyConfig;

use BOM::RPC::Registry '-dsl';

use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook get_doughflow_language_code_for );
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email   qw(send_email);
use BOM::User::AuditLog;
use BOM::Platform::RiskProfile;
use BOM::Platform::Client::CashierValidation;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::RPC::v3::MT5::Account;
use BOM::Platform::CryptoCashier::API;
use BOM::RPC::v3::Trading;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Database::Model::HandoffToken;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::ClientDB;
use BOM::Platform::Event::Emitter;
use BOM::TradingPlatform;
use BOM::Config::Redis;
use BOM::Rules::Engine;
use BOM::TradingPlatform::Helper::HelperDerivEZ;
use BOM::Config::BrokerDatabase;

requires_auth('trading', 'wallet');

use Log::Any qw($log);

use constant {
    MAX_DESCRIPTION_LENGTH           => 250,
    HANDOFF_TOKEN_TTL                => 5 * 60,
    TRANSFER_OVERRIDE_ERROR_CODES    => [qw(FinancialAssessmentRequired)],
    CRYPTO_CONFIG_RPC_REDIS          => "rpc::cryptocurrency::crypto_config",
    CRYPTO_ESTIMATIONS_RPC_CACHE     => "rpc::cryptocurrency::crypto_estimations",
    CRYPTO_ESTIMATIONS_RPC_CACHE_TTL => 5,
    MT5                              => 'mt5',
    DXTRADE                          => 'dxtrade',
    DERIVEZ                          => 'derivez',
    PA_JUSTIFICATION_PREFIX          => 'PA_WITHDRAW_JUSTIFICATION_SUBMIT::',
    PA_JUSTIFICATION_TTL             => 60 * 60 * 24,                                # 24 hours in sec
    CTRADER                          => 'ctrader',
};

my $payment_limits = BOM::Config::payment_limits;

rpc "cashier", sub {
    my $params           = shift;
    my $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, ['compliance_checks']);
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
    my $type     = $args->{type}     // 'url';

    my $is_dry_run = ($provider eq 'crypto' and $type eq 'api' and $args->{dry_run}) ? 1 : 0;

    # this should come before all validation as verification
    # token is mandatory for withdrawal.
    if ($action eq 'withdraw') {
        my $token = $args->{verification_code} // '';

        my $email = $client->email;
        if (not $email or $email =~ /\s+/) {
            return $error_sub->(localize("Please provide a valid email address."));
        } elsif ($token) {
            if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($token, $email, 'payment_withdraw', $is_dry_run)->{error}) {
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
    }

    my $cashier_validation_error = BOM::RPC::v3::Utility::cashier_validation($client, $action);
    return $cashier_validation_error if $cashier_validation_error;

    my ($brand, $currency) = (request()->brand, $client->default_account->currency_code());

    # We need it for backward compatibility, previously provider could be only doughflow
    # and in realty we ignored this value.
    if (LandingCompany::Registry::get_currency_type($currency) eq 'crypto') {
        $provider = 'crypto';
    } elsif ($provider eq 'crypto') {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidRequest',
            message_to_client => localize("Crypto cashier is unavailable for fiat currencies."),
        });
    }

    if ($type eq 'api') {
        if ($provider ne 'crypto') {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidRequest',
                message_to_client => localize("Cashier API doesn't support the selected provider or operation."),
            });
        }

        my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
        if ($action eq 'deposit') {
            return $crypto_service->deposit($client->loginid, $client->currency);
        } elsif ($action eq 'withdraw') {

            my $rule_engine = BOM::Rules::Engine->new(client => $client);
            my $cashier_validation_error =
                BOM::Platform::Client::CashierValidation::validate_crypto_withdrawal_request($client, $args->{address}, $args->{amount},
                $rule_engine);

            return $cashier_validation_error if ($cashier_validation_error);
            # get the locked min withdrawal if available in redis
            my $client_locked_min_withdrawal_amount = BOM::RPC::v3::Utility::get_client_locked_min_withdrawal_amount($client->loginid);
            return $crypto_service->withdraw($client->loginid, $args->{address}, $args->{amount}, $is_dry_run, $client->currency,
                $client_locked_min_withdrawal_amount);
        }
    }

    if ($provider eq 'crypto') {
        return _get_cryptocurrency_cashier_url({
            loginid      => $client->loginid,
            website_name => $params->{website_name},
            currency     => $currency,
            action       => $action,
            language     => $params->{language},
            brand_name   => $brand->name,
            domain       => $params->{domain},
            app_id       => $params->{app_id} // $params->{source},
        });
    }

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $client->loginid});
    # hit DF's CreateCustomer API
    my $header = HTTP::Headers->new();
    $header->header('User-Agent' => 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:47.0) Gecko/20100101 Firefox/47.0');
    my $ua = LWP::UserAgent->new(
        timeout         => 20,
        default_headers => $header
    );
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE
    );    #temporarily disable host verification as full ssl certificate chain is not available in doughflow.

    my $doughflow_loc   = BOM::Config::third_party()->{doughflow}->{$brand->name};
    my $is_white_listed = any { $params->{domain} and $params->{domain} eq $_ } BOM::Config->domain->{white_list}->@*;
    my $domain          = $params->{domain} // '';
    if (!$domain) {
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.empty_doughflow_domain.count');
    } elsif (!$is_white_listed) {
        $log->infof('Trying to access doughflow from an unrecognized domain: %s', $domain);
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.invalid_doughflow_domain.count', {tags => ["domain:@{[ $domain ]}"]});
    }
    $doughflow_loc = "https://cashier.@{[ $domain ]}" if $is_white_listed;

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
                    . "Loginid: "
                    . $client->loginid . "\n"
                    . "Doughflow response: [$errortext]");

            return $error_sub->(
                localize(
                    'Sorry, there was a problem validating your personal information with our payment processor. Please check your details and try again.'
                ),
                'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
            );
        }

        if (my @error_fields = ($errortext =~ /\b(province|country|city|street|pcode|phone|email)\b/g)) {

            # map to our form fields
            my %mapping = (
                province => "address_state",
                country  => "residence",
                city     => "address_city",
                street   => "address_line_1",
                pcode    => "address_postcode"
            );

            for my $field (@error_fields) {
                $field = $mapping{$field} // $field;
            }

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'ASK_FIX_DETAILS',
                    message_to_client => localize('There was a problem validating your personal details.'),
                    details           => {fields => \@error_fields}});
        }

        # check if the client is too old or too young to use doughflow
        my $age_error = _age_error($client, $error_sub, $errortext);
        return $age_error if $age_error;

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
        if (not $client->is_virtual and not $client->has_deposits) {
            $client->status->upsert('deposit_attempt', 'system', 'Client attempted deposit');
        }
    } elsif ($action eq 'withdraw') {
        $action = 'PAYOUT';
    }

    Path::Tiny::path('/tmp/doughflow_tokens.txt')
        ->append_utf8(join(":", Date::Utility->new()->datetime_ddmmmyy_hhmmss, $df_client->loginid, $handoff_token_key, $action));

    # build DF link.
    # udef1 and udef2 are custom DF params we use for language and brand
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
        . $action
        . '&udef1='
        . $params->{language}
        . '&udef2='
        . $brand->name;
    BOM::User::AuditLog::log('redirecting to doughflow', $df_client->loginid);
    return $url;
};

=head2 _age_error

check if the doughflow error is related to the customer age
if yes, it will send an email and return the error in case of
the age to be over 110 or below 18.

=over 4

=item* C<loginid> client login ID

=item* C<error> doughflow error string

=back

C<undef> for errors not related to the customer's age.
error hashref for errors related to the customers age.

=cut

sub _age_error {
    my ($client, $error_sub, $error) = @_;

    my $message =
          "The Doughflow server refused to process the request due to customer age.\n"
        . "There is currently a hardcoded limit on their system which rejects anyone %s years old.\n"
        . "If the client's details have been confirmed as valid, we will need to raise this issue with\n"
        . "the Doughflow support team.\n"
        . "Loginid: %s\n"
        . "Doughflow response: [%s]";

    if ($error =~ /customer underage/) {
        # https://github.com/regentmarkets/doughflow/blob/5f425951d3af40b6d98ac6ab115c2a668d6f9783/Websites/Cashier/CreateCustomer.asp#L147
        $client->add_note('DOUGHFLOW_MIN_AGE_LIMIT_EXCEEDED', sprintf($message, 'under 18', $client->loginid, $error));
    } elsif ($error =~ /customer too old/) {
        # https://github.com/regentmarkets/doughflow/blob/5f425951d3af40b6d98ac6ab115c2a668d6f9783/Websites/Cashier/CreateCustomer.asp#L150
        $client->add_note('DOUGHFLOW_AGE_LIMIT_EXCEEDED', sprintf($message, 'over 110', $client->loginid, $error));
    } else {
        return undef;
    }

    return $error_sub->(
        localize(
            'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.'
        ),
        'Error with DF CreateCustomer API loginid[' . $client->loginid . '] error[' . $error . ']'
    );
}

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
            expires        => time + HANDOFF_TOKEN_TTL,
        },
    );
    $handoff_token->save;

    return $handoff_token->key;
}

sub _get_cryptocurrency_cashier_url {
    return _get_cashier_url('cryptocurrency', @_);
}

sub _get_cashier_url {
    my ($prefix, $args) = @_;

    my ($loginid, $website_name, $currency, $action, $language, $brand_name, $domain, $app_id) =
        @{$args}{qw/loginid website_name currency action language brand_name domain app_id/};

    $prefix = lc($currency) if $prefix eq 'cryptocurrency';

    BOM::User::AuditLog::log("redirecting to $prefix");

    $language = uc($language // 'EN');

    my $url = 'https://';
    if (($website_name // '') =~ /qa/) {
        $url .= lc($website_name) . "/cryptocurrency/$prefix";
    } else {
        my $is_white_listed = $domain && (any { $domain eq $_ } BOM::Config->domain->{white_list}->@*);
        $domain = BOM::Config->domain->{default_domain} unless $domain and $is_white_listed;
        $url .= "crypto-cashier.$domain/cryptocurrency/$prefix";
    }

    $url .=
          "/handshake?token="
        . _get_handoff_token_key($loginid)
        . "&loginid=$loginid&currency=$currency&action=$action&l=$language&brand=$brand_name&app_id=$app_id";

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

    my $landing_company = LandingCompany::Registry->by_broker($client->broker)->short;
    my ($wl_config, $currency) = ($payment_limits->{withdrawal_limits}->{$landing_company}, $client->currency);

    my $limit = +{
        account_balance => formatnumber('amount', $currency, $client->get_limit_for_account_balance),
        payout          => formatnumber('price',  $currency, $client->get_limit_for_payout),
        open_positions  => $client->get_limit_for_open_positions,
    };

    # Returns account balance as null when unlimited account is configured and amount is zero
    $limit->{account_balance} = undef
        if $client->landing_company->unlimited_balance
        && $limit->{account_balance} == 0;

    my $market_specifics = BOM::Platform::RiskProfile::get_current_profile_definitions($client);
    for my $limits (values %$market_specifics) {
        for my $market (@$limits) {
            $market->{name} = localize($market->{name});
        }
    }
    $limit->{market_specific} = $market_specifics;

    my $numdays               = $wl_config->{for_days};
    my $numdayslimit          = $wl_config->{limit_for_days};
    my $lifetimelimit         = $wl_config->{lifetime_limit};
    my $withdrawal_limit_curr = $wl_config->{currency};

    if ($client->fully_authenticated or $client->landing_company->skip_authentication) {
        $numdayslimit  = $wl_config->{limit_for_days_for_authenticated};
        $lifetimelimit = $wl_config->{lifetime_limit_for_authenticated};
    }

    $limit->{num_of_days}       = $numdays;
    $limit->{num_of_days_limit} = formatnumber('price', $currency, convert_currency($numdayslimit,  $withdrawal_limit_curr, $currency));
    $limit->{lifetime_limit}    = formatnumber('price', $currency, convert_currency($lifetimelimit, $withdrawal_limit_curr, $currency));

    # Withdrawal since $numdays
    my $payment_mapper        = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
    my $withdrawal_for_x_days = $payment_mapper->get_total_withdrawal({
        start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
        exclude    => ['currency_conversion_transfer', 'account_transfer'],
    });
    $withdrawal_for_x_days = convert_currency($withdrawal_for_x_days, $currency, $withdrawal_limit_curr);

    # withdrawal since inception
    my $withdrawal_since_inception =
        convert_currency($payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer', 'account_transfer']}),
        $currency, $withdrawal_limit_curr);

    my $remainder = min(($numdayslimit - $withdrawal_for_x_days), ($lifetimelimit - $withdrawal_since_inception));
    if ($remainder <= 0) {
        $remainder = 0;
        BOM::Platform::Event::Emitter::emit('withdrawal_limit_reached', {loginid => $client->loginid});
    }

    $limit->{withdrawal_since_inception_monetary} =
        formatnumber('price', $currency, convert_currency($withdrawal_since_inception, $withdrawal_limit_curr, $currency));
    $limit->{withdrawal_for_x_days_monetary} =
        formatnumber('price', $currency, convert_currency($withdrawal_for_x_days, $withdrawal_limit_curr, $currency));
    $limit->{remainder} = formatnumber('price', $currency, convert_currency($remainder, $withdrawal_limit_curr, $currency));

    # also add Daily Transfer Limits
    if (defined $client->default_account) {
        my $daily_transfer_limits = {
            internal => {
                config  => 'between_accounts',
                counter => undef,
            },
            mt5 => {
                config  => 'MT5',
                counter => 'MT5',
            },
            dxtrade => {
                config  => DXTRADE,
                counter => DXTRADE,
            },
            derivez => {
                config  => DERIVEZ,
                counter => DERIVEZ,
            },
            ctrader => {
                config  => CTRADER,
                counter => CTRADER,
            },
        };
        my $is_daily_cumulative_limit_enabled =
            BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable;
        $limit->{daily_cumulative_amount_transfers}->{enabled} = $is_daily_cumulative_limit_enabled;
        for my $transfer (keys $daily_transfer_limits->%*) {
            my ($config, $counter) = @{$daily_transfer_limits->{$transfer}}{qw/config counter/};
            my $transfers_limit   = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->$config;
            my $transfers_counter = $client->user->daily_transfer_count($counter);
            my $available         = $transfers_limit - $transfers_counter;

            $limit->{daily_transfers}->{$transfer} = {
                allowed   => $transfers_limit,
                available => $available > 0 ? $available : 0,
            };

            my $transfers_amount_limit =
                BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->$config // 0;

            next if $transfers_amount_limit < 0;
            my $transfers_amount = $client->user->daily_transfer_amount($counter);
            my $available_amount = $transfers_amount_limit - $transfers_amount;
            $limit->{daily_cumulative_amount_transfers}->{$transfer} = {
                allowed   => $transfers_amount_limit,
                available => $available_amount > 0 ? $available_amount : 0,
            };
        }
    }
    return $limit;
};

rpc "paymentagent_list",
    auth => [],    # unauthenticated
    sub {
    my $params = shift;

    my ($language, $args, $token_details) = @{$params}{qw/language args token_details/};

    my $target_country = $args->{paymentagent_list};
    my $currency       = $args->{currency};

    if ($currency) {
        my $invalid_currency = BOM::Platform::Client::CashierValidation::invalid_currency_error($currency);
        return BOM::RPC::v3::Utility::create_error($invalid_currency) if $invalid_currency;
    }

    my $loginid;
    my $broker_code = 'CR';
    if (ref $token_details eq 'HASH') {
        $loginid = $token_details->{loginid};
        my $client = BOM::User::Client->get_client_instance($loginid, 'replica');
        $broker_code = $client->broker_code if $client;
    }
    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $all_pa_countries     = $payment_agent_mapper->get_all_authenticated_payment_agent_countries();
    my @available_countries  = grep { !is_payment_agents_suspended_in_country($_->[0]) } @$all_pa_countries;

    # add country name plus code
    foreach (@available_countries) {
        $_->[1] = Brands->new(name => request()->brand)->countries_instance->countries->localized_code2country($_->[0], $language);
    }
    my $available_payment_agents = _get_available_payment_agents($target_country, $broker_code, $currency, $loginid, 1);

    my $payment_agent_list = [];
    foreach my $loginid (keys %{$available_payment_agents}) {
        my $payment_agent = $available_payment_agents->{$loginid};
        my $currency      = $payment_agent->{currency_code};

        my $min_max;
        try {
            $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);
        } catch ($e) {
            log_exception();
            $log->warnf('%s dropped from PA list. Failed to retrieve limits: %s', $loginid, $e);
            next;
        }

        push @{$payment_agent_list},
            {
            'paymentagent_loginid'      => $loginid,
            'name'                      => $payment_agent->payment_agent_name,
            'summary'                   => $payment_agent->summary,
            'urls'                      => $payment_agent->urls,
            'email'                     => $payment_agent->email,
            'phone_numbers'             => $payment_agent->phone_numbers,
            'currencies'                => $currency,
            'deposit_commission'        => $payment_agent->commission_deposit,
            'withdrawal_commission'     => $payment_agent->commission_withdrawal,
            'further_information'       => $payment_agent->information,
            'supported_payment_methods' => $payment_agent->supported_payment_methods,
            'max_withdrawal'            => $payment_agent->max_withdrawal || $min_max->{maximum},
            'min_withdrawal'            => $payment_agent->min_withdrawal || $min_max->{minimum},
            };
    }
    @$payment_agent_list = sort { lc($a->{name}) cmp lc($b->{name}) } @$payment_agent_list;

    return {
        available_countries => \@available_countries,
        list                => $payment_agent_list
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
        my ($message_to_client, %error) = @_;

        BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentTransferError',
            message_to_client => $message_to_client,
            $error{details} ? (details => $error{details}) : (),
        });
    };
    # Simple regex plus precision check via precision.yml
    my $amount_validation_error = validate_amount($amount, $currency);
    return $error_sub->($amount_validation_error) if $amount_validation_error;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    if ($app_config->system->suspend->payments or $app_config->system->suspend->payment_agents) {
        return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'));
    }

    # Reads fiat/crypto from landing_companies.yml, then gets min/max from paymentagent_config.yml
    my ($payment_agent, $paymentagent_error);
    try {
        $payment_agent = BOM::User::Client::PaymentAgent->new({
            'loginid'    => $loginid_fm,
            db_operation => 'replica'
        });
    } catch ($e) {
        log_exception();
        $paymentagent_error = $e;
    }
    if ($paymentagent_error or not $payment_agent) {
        return $error_sub->(localize('You are not authorized for transfers via payment agents.'));
    }

    my $client_to = eval { BOM::User::Client->get_client_instance($loginid_to, 'write') }
        or return $error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to));

    #lets make sure that payment is transfering to client of allowed countries.
    my $pa_target_countries = $payment_agent->get_countries;
    my $is_country_allowed  = any { $client_to->residence eq $_ } @$pa_target_countries;
    my $email_marketing     = request()->brand->emails('marketing');
    return $error_sub->(
        localize(
            "We're unable to process this transfer because the client's resident country is not within your portfolio. Please contact [_1] for more info.",
            $email_marketing
        )) if (not $is_country_allowed and not _is_pa_residence_exclusion($client_fm));

    #disable/suspending pa transfers in a country, does not exclude a pa if a previous transfer is recorded in db.
    if (is_payment_agents_suspended_in_country($client_to->residence)) {
        my $available_payment_agents_for_client =
            _get_available_payment_agents($client_to->residence, $client_to->broker_code, $currency, $loginid_to);

        return $error_sub->(localize("Payment agent transfers are temporarily unavailable in the client's country of residence."))
            unless $available_payment_agents_for_client->{$client_fm->loginid};
    }

    return $error_sub->(localize('Notes must not exceed [_1] characters.', MAX_DESCRIPTION_LENGTH))
        if (length($description) > MAX_DESCRIPTION_LENGTH);

    my $cashier_error = BOM::Platform::Client::CashierValidation::check_availability($client_fm, 'withdrawal');
    if (exists $cashier_error->{error}) {
        return $error_sub->($cashier_error->{error}{message_to_client});
    }

    my $rule_engine = BOM::Rules::Engine->new(client => [$client_fm, $client_to]);
    try {
        $rule_engine->verify_action(
            'paymentagent_transfer',
            loginid_pa     => $loginid_fm,
            loginid_client => $loginid_to,
            amount         => $amount,
            currency       => $currency
        );
    } catch ($e) {
        return _process_pa_transfer_error($e, $currency, $loginid_fm, $loginid_to);
    };

    if ($args->{dry_run}) {
        return {
            status              => 2,
            client_to_full_name => $client_to->full_name,
            client_to_loginid   => $client_to->loginid
        };
    }

    # execute the transfer
    my $now       = Date::Utility->new;
    my $today     = $now->datetime_ddmmmyy_hhmmss_TZ;
    my $reference = Data::UUID->new()->create_str();
    my $comment =
          'Transfer from Payment Agent '
        . $payment_agent->payment_agent_name
        . " ($loginid_fm)"
        . " to $loginid_to. Transaction reference: $reference. Timestamp: $today."
        . ($description ? " Agent note: $description" : '');

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
        );
    } catch ($e) {
        log_exception();
        $error = $e;
    }

    if ($error) {
        if (ref $error ne 'ARRAY') {
            return $error_sub->(localize("Sorry, an error occurred whilst processing your request."));
        }

        my ($error_code, $error_msg) = @$error;

        if ($error_code eq 'BI101') {
            return $error_sub->(localize('Your account balance is insufficient for this transaction.'));
        } elsif ($error_code eq 'BI102') {
            # too many attempts
            return $error_sub->(localize('Request too frequent. Please try again later.'));
        } else {
            $log->fatalf('Unexpected DB error: %s', $error);
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'), $error_msg);
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

    BOM::Platform::Event::Emitter::emit(
        'pa_transfer_confirm',
        {
            loginid       => $client_to->loginid,
            email         => $client_to->email,
            client_name   => $client_to->first_name . ' ' . $client_to->last_name,
            pa_loginid    => $client_fm->loginid,
            pa_first_name => $client_fm->first_name,
            pa_last_name  => $client_fm->last_name,
            pa_name       => $client_fm->payment_agent->payment_agent_name,
            amount        => formatnumber('amount', $currency, $amount),
            currency      => $currency,
            language      => $params->{language},
        });

    $payment_agent->newly_authorized(0);    # reset the 'newly_authorized' flag

    return {
        status              => 1,
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to,
        transaction_id      => $response->{transaction_id}};
};

=head2 _process_pa_transfer_error

Convers payment agent rule engine error into the proper RPC error.

It gets the following args:

=over 4

=item * rules_error: The rule engine error.

=back

=cut

sub _process_pa_transfer_error {
    my ($rules_error, $currency, $pa_loginid, $client_loginid) = @_;

    die $rules_error unless ref $rules_error eq 'HASH';
    my $error_code = $rules_error->{error_code} // $rules_error->{code} // '';
    $rules_error->{tags} //= [];
    my $fail_side = (any { $_ eq 'pa' } $rules_error->{tags}->@*) ? 'pa' : 'client';

    # some error messages are different for PA and client
    my %error_code_mapping = (
        pa => {
            CurrencyMismatch => {
                code   => 'PACurrencyMismatch',
                params => [$currency, $pa_loginid],
            },
            PaymentagentNotAuthenticated => {code => 'NotAuthentorized'}
        },
        client => {
            CurrencyMismatch => {
                code   => 'ClientCurrencyMismatch',
                params => [$currency, $client_loginid],
            },
            CashierLocked => {
                code   => 'ClientCashierLocked',
                params => [$client_loginid],
            },
            DisabledAccount => {
                code   => 'ClientDisabledAccount',
                params => [$client_loginid],
            },
            DocumentsExpired => {
                code   => 'ClientDocumentsExpired',
                params => [$client_loginid],
            },
            CashierRequirementsMissing => {
                code   => 'ClientRequirementsMissing',
                params => [$client_loginid],
            },
            UnwelcomeStatus => {
                code   => 'PATransferClientFailure',
                params => [$client_loginid],
            },
            SelfExclusion => {
                code   => 'PATransferClientFailure',
                params => [$client_loginid],
            },
            SetExistingAccountCurrency => {
                code   => 'PATransferClientFailure',
                params => [$client_loginid],
            },
        },
    );
    if (my $new_error = $error_code_mapping{$fail_side}->{$error_code}) {
        $rules_error->{error_code} = $new_error->{code};
        $rules_error->{params}     = $new_error->{params};
    }

    my $rpc_error = BOM::RPC::v3::Utility::rule_engine_error($rules_error, 'PaymentAgentTransferError');

    # Special treatment for missing-requiremets error (only for PA side)
    $rpc_error->{error}->{code} = 'ASK_FIX_DETAILS' if $error_code eq 'CashierRequirementsMissing' && $fail_side eq 'pa';

    return $rpc_error;
}

sub _get_json_error {
    my $error = shift;
    $error = $1 if $error =~ /ERROR:  (.+)/;
    return decode_json($error);
}

=head2 _get_available_payment_agents

	my $available_agents = _get_available_payment_agents('id', 'CR', 'USD', 'CR90000', 1);

Returns a hash reference containing authenticated payment agents available for the input search criteria.

It gets the following args:

=over 4

=item * country

=item * broker_code

=item * currency (optional)

=item * client_loginid (optional), it is used for retrieving payment agents with previous transfer/withdrawal with a C<client> when the feature is suspended in the C<country> of residence.

=item * is_listed

=back

=cut

sub _get_available_payment_agents {
    my ($country, $broker_code, $currency, $loginid, $is_listed) = @_;
    my $payment_agent_mapper              = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $authenticated_paymentagent_agents = BOM::User::Client::PaymentAgent->get_payment_agents(
        country_code => $country,
        broker_code  => $broker_code,
        currency     => $currency,
        is_listed    => $is_listed,
    );

    #if payment agents are suspended in client's country, we will keep only those agents that the client has previously transfered money with.
    if (is_payment_agents_suspended_in_country($country)) {
        my $linked_pas    = $payment_agent_mapper->get_payment_agents_linked_to_client($loginid);
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
    my $paymentagent_client  = shift;
    my $residence_exclusions = BOM::Config::Runtime->instance->app_config->payments->payment_agent_residence_check_exclusion;
    return ($paymentagent_client && (grep { $_ eq $paymentagent_client->email } @$residence_exclusions)) ? 1 : 0;
}

rpc paymentagent_withdraw => sub {
    my $params = shift;

    my $source                     = $params->{source};
    my $source_bypass_verification = $params->{source_bypass_verification} // 0;
    my $client                     = $params->{client};

    my ($website_name, $args) = @{$params}{qw/website_name args/};

    # validate token
    # - when its not dry run
    # - when bypass flag is not set for an app id
    my $dry_run = $args->{dry_run} // 0;
    if ($dry_run == 0 and $source_bypass_verification == 0) {
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

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'))
        if ($app_config->system->suspend->payment_agents);

    # check that the additional information does not exceeded the allowed limits
    return $error_sub->(localize('Further instructions must not exceed [_1] characters.', MAX_DESCRIPTION_LENGTH))
        if (length($further_instruction) > MAX_DESCRIPTION_LENGTH);

    my $amount_validation_error = validate_amount($amount, $currency);
    return $error_sub->($amount_validation_error) if $amount_validation_error;

    my ($paymentagent, $paymentagent_error);
    try {
        $paymentagent = BOM::User::Client::PaymentAgent->new({
            'loginid'    => $paymentagent_loginid,
            db_operation => 'replica'
        });
    } catch ($e) {
        log_exception();
        $paymentagent_error = $e;
    }
    if ($paymentagent_error or not $paymentagent) {
        return $error_sub->(localize('Please enter a valid payment agent ID.'));
    }
    my $pa_client = $paymentagent->client;
    if (is_payment_agents_suspended_in_country($client->residence)) {
        my $available_payment_agents_for_client =
            _get_available_payment_agents($client->residence, $client->broker_code, $currency, $client->loginid);
        return $error_sub->(localize("Payment agent transfers are temporarily unavailable in the client's country of residence."))
            unless $available_payment_agents_for_client->{$pa_client->loginid};
    }

    my $cashier_error = BOM::Platform::Client::CashierValidation::check_availability($client, 'withdraw');
    if (exists $cashier_error->{error}) {
        return $error_sub->($cashier_error->{error}{message_to_client});
    }

    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $pa_client]);
    try {
        $rule_engine->verify_action(
            'paymentagent_withdraw',
            loginid_client             => $client_loginid,
            loginid_pa                 => $paymentagent_loginid,
            amount                     => $amount,
            currency                   => $currency,
            dry_run                    => $args->{dry_run} // 0,
            source_bypass_verification => $source_bypass_verification,
        );
    } catch ($e) {
        return _process_pa_withdraw_error($e, $currency, $client_loginid, $paymentagent_loginid);
    }

    # lets make sure that client is withdrawing to payment agent having allowed countries.
    my $pa_target_countries = $paymentagent->get_countries;
    my $is_country_allowed  = any { $client->residence eq $_ } @$pa_target_countries;
    my $email_marketing     = request()->brand->emails('marketing');
    return $error_sub->(
        localize(
            "We're unable to process this withdrawal because your country of residence is not within the payment agent's portfolio. Please contact [_1] for more info.",
            $email_marketing
        )) if (not $is_country_allowed and not _is_pa_residence_exclusion($pa_client));

    if ($args->{dry_run}) {
        return {
            status            => 2,
            paymentagent_name => $paymentagent->payment_agent_name
        };
    }

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $client_loginid,
    });

    my $comment =
          'Transfer from '
        . $client_loginid
        . ' to Payment Agent '
        . $paymentagent->payment_agent_name
        . " ($paymentagent_loginid)"
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
    } catch ($e) {
        log_exception();
        $error = $e;
    }

    if ($error) {
        if (ref $error ne 'ARRAY') {
            return $error_sub->(localize("Sorry, an error occurred whilst processing your request."));
        }

        my ($error_code, $error_msg) = @$error;

        my $full_error_msg = "Paymentagent Withdraw failed to $paymentagent_loginid [$error_msg]";

        if ($error_code eq 'BI101') {
            return $error_sub->(localize('Your account balance is insufficient for this transaction.'));
        } elsif ($error_code eq 'BI102') {
            # too many attempts
            return $error_sub->(localize('Request too frequent. Please try again later.'));
        } else {
            $log->fatalf('Unexpected DB error: %s', $error);
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'), $error_msg);
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

    BOM::Platform::Event::Emitter::emit(
        'pa_withdraw_confirm',
        {
            loginid        => $pa_client->loginid,
            email          => $pa_client->email,
            client_name    => $client->first_name . ' ' . $client->last_name,
            client_loginid => $client->loginid,
            pa_first_name  => $pa_client->first_name,
            pa_last_name   => $pa_client->last_name,
            pa_name        => $pa_client->full_name,
            pa_loginid     => $pa_client->loginid,
            amount         => formatnumber('amount', $currency, $amount),
            currency       => $currency,
            language       => $params->{language},
        });

    $paymentagent->newly_authorized(0);    # reset the 'newly_authorized' flag

    return {
        status            => 1,
        paymentagent_name => $paymentagent->payment_agent_name,
        transaction_id    => $response->{transaction_id}};
};

sub _process_pa_withdraw_error {
    my ($rules_error, $currency, $client_loginid, $pa_loginid) = @_;

    die $rules_error unless ref $rules_error eq 'HASH';
    my $error_code = $rules_error->{error_code} // $rules_error->{code} // '';
    $rules_error->{tags} //= [];
    my $fail_side = (any { $_ eq 'pa' } $rules_error->{tags}->@*) ? 'pa' : 'client';

    my %error_mapping = (
        SameAccountNotAllowed     => 'PASameAccountWithdrawal',
        DifferentLandingCompanies => 'PAWithdrawalDifferentBrokers',
        AmountExceedsBalance      => 'ClientInsufficientBalance',
        client                    => {
            CurrencyMismatch => {
                code   => 'ClientCurrencyMismatchWithdraw',
                params => [$currency, $client_loginid]}
        },
        pa => {
            CurrencyMismatch => {
                code   => 'PACurrencyMismatchWithdraw',
                params => [$currency, $pa_loginid]
            },
            DisabledAccount => {
                code   => 'PADisabledAccountWithdraw',
                params => [$pa_loginid]
            },
            UnwelcomeStatus => {
                code   => 'PAUnwelcomeStatusWithdraw',
                params => [$pa_loginid]
            },
            CashierLocked => {
                code   => 'PACashierLockedWithdraw',
                params => [$pa_loginid]
            },
            DocumentsExpired => {
                code   => 'PADocumentsExpiredWithdraw',
                params => [$pa_loginid]}});

    if (my $new_error = $error_mapping{$fail_side}->{$error_code}) {
        $error_code = $new_error->{code};
        $rules_error->{params} = $new_error->{params};
    }
    $rules_error->{error_code} = $error_mapping{$error_code} // $error_code;

    return BOM::RPC::v3::Utility::rule_engine_error($rules_error, 'PaymentAgentWithdrawError');
}

rpc paymentagent_withdraw_justification => sub {
    my $params = shift;

    my $loginid       = $params->{client}->loginid;
    my $justification = $params->{args}{message};
    my $brand         = request()->brand;
    my $redis         = BOM::Config::Redis::redis_replicated_write();

    unless ($redis->set(PA_JUSTIFICATION_PREFIX . $loginid, 1, 'NX', 'EX', PA_JUSTIFICATION_TTL)) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'JustificationAlreadySubmitted',
                message_to_client => localize('You cannot submit another payment agent withdrawal justification within 24 hours.')});
    }

    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('payments'),
        subject => "Payment agent withdraw justification submitted by $loginid at " . Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ,
        message => [$justification],
    });

    return 1;
};

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

    return "Includes transfer fee of "
        . formatnumber(
        amount => $args{fees_currency},
        $args{fee_calculated_by_percent})
        . " $args{fees_currency} ($args{fees_percent}%)."
        if $args{fee_calculated_by_percent} >= $args{min_fee};

    return "Includes the minimum transfer fee of $args{min_fee} $args{fees_currency}.";
}

rpc transfer_between_accounts => sub {
    my $params = shift;
    my ($client, $source, $token) = @{$params}{qw/client source token/};
    my $token_type = $params->{token_type} // '';
    my $lc_short   = $client->landing_company->short;

    my $args = $params->{args};
    my ($currency, $amount) = @{$args}{qw/currency amount/};
    my $status                = $client->status;
    my $transfers_blocked_err = localize("Transfers are not allowed for these accounts.");

    my ($loginid_from, $loginid_to) = @{$args}{qw/account_from account_to/};

    # retrieve disabled accounts just in order to return relevant error messages for them
    my $siblings = $client->get_siblings_information(include_disabled => 1);

    if (BOM::Config::CurrencyConfig::is_payment_suspended()) {
        return _transfer_between_accounts_error(localize('Payments are suspended.'));
    }

    # just return accounts list if loginid from or to is not provided
    if (not $loginid_from or not $loginid_to) {
        my @available_siblings_for_transfer =
            grep { !$_->{disabled} && $_->{demo_account} == $client->is_virtual && $lc_short eq $_->{landing_company_name} } values %$siblings;

        @available_siblings_for_transfer = map { $_->{account_type} = delete $_->{category}; $_ } map {
            { $_->%{qw/loginid balance account_type currency demo_account category/} }
        } @available_siblings_for_transfer;

        if (($args->{accounts} // '') eq 'all' and not(BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all)) {
            my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($client)->else(sub { return Future->done(); })->get;
            for my $mt5_acc (grep { not $_->{error} } @mt5_accounts) {
                my $is_demo = ($mt5_acc->{account_type} eq 'demo') ? 1 : 0;
                next unless $client->is_virtual == $is_demo;

                # We only should show mt5 account, that can be deposited from current account.
                my $mt_lc = LandingCompany::Registry->by_name($mt5_acc->{landing_company_short});
                next unless grep { $lc_short eq $_ } $mt_lc->mt5_require_deriv_account_at->@*;

                push @available_siblings_for_transfer,
                    {
                    loginid      => $mt5_acc->{login},
                    balance      => $mt5_acc->{display_balance},
                    account_type => MT5,
                    mt5_group    => $mt5_acc->{group},
                    currency     => $mt5_acc->{currency},
                    demo_account => ($mt5_acc->{account_type} eq 'demo') ? 1 : 0,
                    status       => $mt5_acc->{status},
                    }
                    unless any { ($mt5_acc->{status} // '') eq $_ } qw/proof_failed verification_pending/;
            }
        }

        my $dxtrade = BOM::TradingPlatform->new(
            platform => DXTRADE,
            client   => $client,
        );
        my @dxtrade_accounts = $dxtrade->get_accounts(type => $client->is_virtual ? 'demo' : 'real')->@*;

        for my $dxtrade_account (@dxtrade_accounts) {
            next unless $dxtrade_account->{enabled};
            next unless $dxtrade_account->{landing_company_short} eq $lc_short;
            push @available_siblings_for_transfer,
                {
                loginid      => $dxtrade_account->{account_id},
                balance      => $dxtrade_account->{display_balance},
                account_type => DXTRADE,
                market_type  => $dxtrade_account->{market_type},
                currency     => $dxtrade_account->{currency},
                demo_account => ($dxtrade_account->{account_type} eq 'demo') ? 1 : 0,
                };

        }

        my $derivez = BOM::TradingPlatform->new(
            platform => DERIVEZ,
            client   => $client,
        );
        my @derivez_accounts = $derivez->get_accounts(type => $client->is_virtual ? 'demo' : 'real')->@*;
        for my $derivez_account (grep { not $_->{error} } @derivez_accounts) {
            next unless $derivez_account->{landing_company_short} eq $lc_short;
            push @available_siblings_for_transfer,
                {
                loginid       => $derivez_account->{login},
                balance       => $derivez_account->{display_balance},
                account_type  => DERIVEZ,
                derivez_group => $derivez_account->{group},
                currency      => $derivez_account->{currency},
                demo_account  => ($derivez_account->{account_type} eq 'demo') ? 1 : 0,
                status        => $derivez_account->{status},
                };
        }

        my $ctrader = BOM::TradingPlatform->new(
            platform => CTRADER,
            client   => $client,
        );
        my @ctrader_accounts = $ctrader->get_accounts(type => $client->is_virtual ? 'demo' : 'real')->@*;
        for my $ctrader_account (@ctrader_accounts) {
            next unless $ctrader_account->{landing_company_short} eq $lc_short;
            push @available_siblings_for_transfer,
                {
                loginid      => $ctrader_account->{account_id},
                balance      => $ctrader_account->{display_balance},
                account_type => CTRADER,
                currency     => $ctrader_account->{currency},
                demo_account => ($ctrader_account->{account_type} eq 'demo') ? 1 : 0,
                };
        }

        return {
            status   => 0,
            accounts => \@available_siblings_for_transfer
        };
    }

    my @mt5_logins          = $client->user->get_mt5_loginids();
    my $is_mt5_loginid_from = any { $loginid_from eq $_ } @mt5_logins;
    my $is_mt5_loginid_to   = any { $loginid_to eq $_ } @mt5_logins;

    my %loginid_details = $client->user->loginid_details->%*;
    my @dxtrade_loginids =
        grep { ($loginid_details{$_}->{platform} // '') eq DXTRADE and $loginid_details{$_}->{account_type} eq 'real' } keys %loginid_details;
    my $is_dxtrade_loginid_from = any { $loginid_from eq $_ } @dxtrade_loginids;
    my $is_dxtrade_loginid_to   = any { $loginid_to eq $_ } @dxtrade_loginids;

    my @derivez_logins          = $client->user->get_derivez_loginids();
    my $is_derivez_loginid_from = any { $loginid_from eq $_ } @derivez_logins;
    my $is_derivez_loginid_to   = any { $loginid_to eq $_ } @derivez_logins;

    my @ctrader_logins          = $client->user->get_ctrader_loginids();
    my $is_ctrader_loginid_from = any { $loginid_from eq $_ } @ctrader_logins;
    my $is_ctrader_loginid_to   = any { $loginid_to eq $_ } @ctrader_logins;

    # create client from siblings so that we are sure that from and to loginid
    # provided are for same user
    my ($client_from, $client_to, $res);

    try {
        $client_from = BOM::User::Client->get_client_instance($siblings->{$loginid_from}->{loginid}, 'write')
            if $siblings->{$loginid_from};
        $client_to = BOM::User::Client->get_client_instance($siblings->{$loginid_to}->{loginid}, 'write')
            if $siblings->{$loginid_to};
    } catch {
        log_exception();
        $res = _transfer_between_accounts_error();
    }
    return $res if $res;

    # Both $loginid_from and $loginid_to must be either a real or a MT5 account
    # Unfortunately demo MT5 accounts will slip through this check, but they will
    # be caught in one of the BOM::RPC::v3::MT5::Account functions
    my $account_type_from;
    if ($is_mt5_loginid_from) {
        $account_type_from = MT5;
    } elsif ($is_dxtrade_loginid_from) {
        $account_type_from = DXTRADE;
    } elsif ($is_derivez_loginid_from) {
        $account_type_from = DERIVEZ;
    } elsif ($is_ctrader_loginid_from) {
        $account_type_from = CTRADER;
    } elsif ($client_from) {
        $account_type_from = $client_from->is_wallet ? 'wallet' : 'trading';
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize("You are not allowed to transfer from this account.")});
    }

    my $account_type_to;
    if ($is_mt5_loginid_to) {
        $account_type_to = MT5;
    } elsif ($is_dxtrade_loginid_to) {
        $account_type_to = DXTRADE;
    } elsif ($is_derivez_loginid_to) {
        $account_type_to = DERIVEZ;
    } elsif ($is_ctrader_loginid_to) {
        $account_type_to = CTRADER;
    } elsif ($client_to) {
        $account_type_to = $client_to->is_wallet ? 'wallet' : 'trading';
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize("You are not allowed to transfer to this account.")});
    }

    my $is_internal_transfer =
        !( $is_mt5_loginid_from
        || $is_mt5_loginid_to
        || $is_dxtrade_loginid_to
        || $is_dxtrade_loginid_from
        || $is_derivez_loginid_to
        || $is_derivez_loginid_from
        || $is_ctrader_loginid_to
        || $is_ctrader_loginid_from);
    my $rule_engine = BOM::Rules::Engine->new(client => [$client, $client_from // (), $client_to // ()]);
    try {
        $rule_engine->verify_action(
            'transfer_between_accounts',
            loginid              => $client->loginid,
            loginid_from         => $loginid_from,
            loginid_to           => $loginid_to,
            account_type_from    => $account_type_from,
            account_type_to      => $account_type_to,
            amount               => $amount,
            currency             => $currency,
            token_type           => $token_type,
            is_internal_transfer => $is_internal_transfer
        );
    } catch ($e) {
        if (ref $e eq 'HASH' && $e->{error_code}) {
            stats_event(
                'Exchange Rates Issue - No offering to clients',
                'Please inform Quants and Backend Teams to check the exchange_rates for the currency.',
                {
                    alert_type => 'warning',
                    tags       => ['currency:' . $e->{params} . '_USD']}) if $e->{error_code} eq 'ExchangeRatesUnavailable';

            return BOM::RPC::v3::Utility::missing_details_error(details => $e->{details}->{fields})
                if $e->{error_code} eq 'CashierRequirementsMissing';
        }

        return BOM::RPC::v3::Utility::rule_engine_error($e);
    }

    # this transfer involves an MT5 account
    if ($is_mt5_loginid_from or $is_mt5_loginid_to) {
        delete @{$params->{args}}{qw/account_from account_to/};

        my ($method, $binary_login, $mt5_login);

        if ($is_mt5_loginid_to) {
            return _transfer_between_accounts_error(localize("You can only transfer from the current authorized client's account."))
                unless ($client->loginid eq $loginid_from)
                or $token_type eq 'oauth_token'
                or $client_from->is_virtual;

            return _transfer_between_accounts_error(localize('Currency provided is different from account currency.'))
                if ($siblings->{$loginid_from}->{currency} ne $currency);

            $method                             = \&BOM::RPC::v3::MT5::Account::mt5_deposit;
            $params->{args}{from_binary}        = $binary_login = $loginid_from;
            $params->{args}{to_mt5}             = $mt5_login    = $loginid_to;
            $params->{args}{return_mt5_details} = 1;    # to get MT5 account holder name
        }

        if ($is_mt5_loginid_from) {

            return _transfer_between_accounts_error(localize("You can only transfer to the current authorized client's account."))
                unless ($client->loginid eq $loginid_to)
                or $token_type eq 'oauth_token',
                or $client_to->is_virtual;

            $method                         = \&BOM::RPC::v3::MT5::Account::mt5_withdrawal;
            $params->{args}{to_binary}      = $binary_login = $loginid_to;
            $params->{args}{from_mt5}       = $mt5_login    = $loginid_from;
            $params->{args}{currency_check} = $currency;    # this makes mt5_withdrawal() check that MT5 account currency matches $currency
        }

        return $method->($params)->then(
            sub {
                my $resp = shift;
                return Future->done(_transfer_between_accounts_error($resp->{error}{message_to_client})) if ($resp->{error});

                my $mt5_data = delete $resp->{mt5_data};
                $resp->{transaction_id}      = delete $resp->{binary_transaction_id};
                $resp->{client_to_loginid}   = $loginid_to;
                $resp->{client_to_full_name} = $is_mt5_loginid_to ? $mt5_data->{name} : $client->full_name;

                my $binary_client = BOM::User::Client->get_client_instance($binary_login);
                push @{$resp->{accounts}},
                    {
                    loginid      => $binary_login,
                    balance      => $binary_client->default_account->balance,
                    currency     => $binary_client->default_account->currency_code,
                    account_type => $binary_client->get_account_type->category->name,
                    demo_account => $binary_client->is_virtual,
                    };

                BOM::RPC::v3::MT5::Account::mt5_get_settings({
                        client => $client,
                        args   => {login => $mt5_login}}
                )->then(
                    sub {
                        my ($setting) = @_;
                        push @{$resp->{accounts}},
                            {
                            loginid      => $mt5_login,
                            balance      => $setting->{display_balance},
                            currency     => $setting->{currency},
                            account_type => MT5,
                            mt5_group    => $setting->{group},
                            demo_account => ($setting->{group} =~ qr/demo/ ? 1 : 0),
                            }
                            unless $setting->{error};
                        return Future->done($resp);
                    });
            }
        )->catch(
            sub {
                my $err = shift;
                log_exception();
                return Future->done(_transfer_between_accounts_error($err->{error}{message_to_client}, undef, $err->{error}{code}));
            })->get;
    }

    if ($is_dxtrade_loginid_to or $is_dxtrade_loginid_from) {
        $params->{args}->@{qw/from_account to_account/} = delete $params->{args}->@{qw/account_from account_to/};
        $params->{args}{platform} = DXTRADE;
    }

    if ($is_dxtrade_loginid_to) {
        my $deposit = BOM::RPC::v3::Trading::deposit($params);
        return $deposit if $deposit->{error};

        # This endpoint schema expects synthetic or financial (not gaming)
        my $market_type = $deposit->{market_type};
        $market_type = 'synthetic' if $market_type eq 'gaming';

        return {
            status   => 1,
            accounts => [{
                    loginid      => $loginid_from,
                    balance      => $client_from->account->balance,
                    currency     => $client_from->account->currency_code,
                    account_type => $client_from->get_account_type->category->name,
                },
                {
                    loginid      => $loginid_to,
                    balance      => $deposit->{balance},
                    currency     => $deposit->{currency},
                    account_type => DXTRADE,
                    market_type  => $market_type,
                },
            ]};
    }

    if ($is_dxtrade_loginid_from) {
        my $withdrawal = BOM::RPC::v3::Trading::withdrawal($params);
        return $withdrawal if $withdrawal->{error};

        my $to_client = BOM::User::Client->get_client_instance($loginid_to);
        # This endpoint schema expects synthetic or financial (not gaming)
        my $market_type = $withdrawal->{market_type};
        $market_type = 'synthetic' if $market_type eq 'gaming';

        return {
            status   => 1,
            accounts => [{
                    loginid      => $loginid_to,
                    balance      => $to_client->account->balance,
                    currency     => $to_client->account->currency_code,
                    account_type => $to_client->get_account_type->category->name,
                },
                {
                    loginid      => $loginid_from,
                    balance      => $withdrawal->{balance},
                    currency     => $withdrawal->{currency},
                    account_type => DXTRADE,
                    market_type  => $market_type,
                },
            ]};
    }

    # this transfer involves an Derivez account
    if ($is_derivez_loginid_from or $is_derivez_loginid_to) {
        my ($method, $binary_login, $derivez_login);

        my $resp = {};
        if ($is_derivez_loginid_to) {
            return _transfer_between_accounts_error(localize("You can only transfer from the current authorized client's account."))
                unless ($client->loginid eq $loginid_from)
                or $token_type eq 'oauth_token'
                or $client_from->is_virtual;

            return _transfer_between_accounts_error(localize('Currency provided is different from account currency.'))
                if ($siblings->{$loginid_from}->{currency} ne $currency);

            $method                                 = \&BOM::RPC::v3::Trading::deposit;
            $params->{args}{from_account}           = $binary_login  = $loginid_from;
            $params->{args}{to_account}             = $derivez_login = $loginid_to;
            $params->{args}{platform}               = DERIVEZ;
            $params->{args}{return_derivez_details} = 1;         # to get derivez account holder name
        }

        if ($is_derivez_loginid_from) {
            return _transfer_between_accounts_error(localize("You can only transfer to the current authorized client's account."))
                unless ($client->loginid eq $loginid_to)
                or $token_type eq 'oauth_token'
                or $client_to->is_virtual;

            $method                         = \&BOM::RPC::v3::Trading::withdrawal;
            $params->{args}{from_account}   = $derivez_login = $loginid_from;
            $params->{args}{to_account}     = $binary_login  = $loginid_to;
            $params->{args}{platform}       = DERIVEZ;
            $params->{args}{currency_check} = $currency;    # Check that derivez account currency matches $currency
        }

        # Making deposit or withdrawal request
        my $do_request = $method->($params);

        # Return error
        return $do_request if $do_request->{error};

        my $derivez_data = delete $do_request->{derivez_data};
        $resp->{transaction_id}      = delete $do_request->{transaction_id};
        $resp->{client_to_loginid}   = $loginid_to;
        $resp->{client_to_full_name} = $client->full_name;

        my $binary_client = BOM::User::Client->get_client_instance($binary_login);
        push @{$resp->{accounts}},
            {
            loginid      => $binary_login,
            balance      => $binary_client->default_account->balance,
            currency     => $binary_client->default_account->currency_code,
            account_type => $binary_client->get_account_type->category->name,
            demo_account => $binary_client->is_virtual,
            };

        return BOM::TradingPlatform::Helper::HelperDerivEZ::_get_settings($client, $derivez_login)->then(
            sub {
                my ($setting) = @_;
                push @{$resp->{accounts}},
                    {
                    loginid       => $derivez_login,
                    balance       => $setting->{display_balance},
                    currency      => $setting->{currency},
                    account_type  => DERIVEZ,
                    derivez_group => $setting->{group},
                    demo_account  => ($setting->{group} =~ qr/demo/ ? 1 : 0),
                    }
                    unless $setting->{error};
                $resp->{status} = 1;

                return Future->done($resp);
            })->get;
    }

    # cTrader related - Start

    if ($is_ctrader_loginid_to or $is_ctrader_loginid_from) {
        $params->{args}->@{qw/from_account to_account/} = delete $params->{args}->@{qw/account_from account_to/};
        $params->{args}{platform} = CTRADER;
    }

    if ($is_ctrader_loginid_to) {
        my $deposit = BOM::RPC::v3::Trading::deposit($params);
        return $deposit if $deposit->{error};

        # This endpoint schema expects synthetic or financial (not gaming)
        my $market_type = $deposit->{market_type};
        $market_type = 'synthetic' if $market_type eq 'gaming';

        return {
            status   => 1,
            accounts => [{
                    loginid      => $loginid_from,
                    balance      => $client_from->account->balance,
                    currency     => $client_from->account->currency_code,
                    account_type => $client_from->get_account_type->category->name,
                },
                {
                    loginid      => $loginid_to,
                    balance      => $deposit->{balance},
                    currency     => $deposit->{currency},
                    account_type => CTRADER,
                    market_type  => $market_type,
                },
            ]};
    }

    if ($is_ctrader_loginid_from) {
        my $withdrawal = BOM::RPC::v3::Trading::withdrawal($params);
        return $withdrawal if $withdrawal->{error};

        my $to_client = BOM::User::Client->get_client_instance($loginid_to);
        # This endpoint schema expects synthetic or financial (not gaming)
        my $market_type = $withdrawal->{market_type};
        $market_type = 'synthetic' if $market_type eq 'gaming';

        return {
            status   => 1,
            accounts => [{
                    loginid      => $loginid_to,
                    balance      => $to_client->account->balance,
                    currency     => $to_client->account->currency_code,
                    account_type => $to_client->get_account_type->category->name,
                },
                {
                    loginid      => $loginid_from,
                    balance      => $withdrawal->{balance},
                    currency     => $withdrawal->{currency},
                    account_type => CTRADER,
                    market_type  => $market_type,
                },
            ]};
    }

    # cTrader related - End

    my $err = validate_amount($amount, $currency);
    return _transfer_between_accounts_error($err) if $err;

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
        },
        $token_type
    );
    return $res if $res;

    return _transfer_between_accounts_error(localize('This currency is temporarily suspended. Please select another currency to proceed.'))
        if BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $from_currency)
        || BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $to_currency);

    BOM::User::AuditLog::log("Account Transfer ATTEMPT, from[$loginid_from], to[$loginid_to], amount[$amount], curr[$currency]", $loginid_from);
    my $error_audit_sub = sub {
        my ($err, $client_message) = @_;
        BOM::User::AuditLog::log("Account Transfer FAILED, $err");

        my $message_mapping = [{
                regex   => qr/Please set your 30-day turnover limit/,
                message => 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            },
            {
                regex   => qr/Please provide your latest tax information/,
                message => 'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
            },
            {
                regex   => qr/Financial Risk approval is required/,
                message => 'Financial Risk approval is required.',
            },
            {
                regex   => qr/Please authenticate your account/,
                message => 'Please authenticate your account.',
            },
            {
                regex   => qr/BI101/,
                message => 'The sending account has insufficient funds for this transaction.',
            },
            {
                regex   => qr/BI102/,
                message => 'Request too frequent. Please try again later.',
            }];

        foreach ($message_mapping->@*) {
            if ($err =~ $_->{regex}) {
                $client_message = $_->{message};
                last;
            }
        }

        $client_message ||= localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.');
        return _transfer_between_accounts_error($client_message);
    };

    my ($to_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent);
    try {
        ($to_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
            amount        => $amount,
            from_currency => $from_currency,
            to_currency   => $to_currency,
            from_client   => $client_from,
            to_client     => $client_to,
            country       => $client_from->residence,
            );
    } catch ($err) {
        log_exception();

        return $error_audit_sub->($err, localize('Sorry, transfers are currently unavailable. Please try again later.'))
            if ($err =~ /No rate available to convert/);

        return $error_audit_sub->($err, localize('Account transfers are not possible between [_1] and [_2].', $from_currency, $to_currency))
            if ($err =~ /No transfer fee/);

        # Lower than min_unit in the receiving currency. The lower-bounds are not uptodate, otherwise we should not accept the amount in sending currency.
        # To update them, transfer_between_accounts_fees is called again with force_refresh on.
        return $error_audit_sub->(
            $err,
            localize(
                "This amount is too low. Please enter a minimum of [_2] [_1].",
                $from_currency,
                formatnumber('amount', $from_currency, BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{$from_currency}->{min}))
        ) if ($err =~ /The amount .* is below the minimum allowed amount .* for $to_currency/);

        return $error_audit_sub->($err);
    }

    my $err_msg = "from[$loginid_from], to[$loginid_to], amount[$amount], curr[$currency]";
    $rule_engine = BOM::Rules::Engine->new(client => [$client_from, $client_to]);

    unless ($client_from->is_virtual) {
        try {
            $client_from->validate_payment(
                currency     => $currency,
                amount       => -1 * $amount,
                payment_type => 'internal_transfer',
                rule_engine  => $rule_engine,
            );
        } catch ($err) {
            log_exception();

            my $limit;
            if ($err->{code} eq 'AmountExceedsBalance') {
                my $currency = $err->{params}->[1];
                my $balance  = $err->{params}->[2];

                $limit = join ' ', $currency, $balance;
            } elsif ($err->{code} eq 'AmountExceedsUnfrozenBalance') {
                my $currency     = $err->{params}->[1];
                my $balance      = $err->{params}->[2];
                my $frozen_bonus = $err->{params}->[3];

                $limit = join ' ', $currency, $balance - $frozen_bonus;
            }

            my $msg = (defined $limit) ? localize("The maximum amount you may transfer is: [_1].", $limit) : $err->{message_to_client};
            return $error_audit_sub->("validate_payment failed for $loginid_from [$err]", $msg);
        }
    }

    unless ($client_to->is_virtual) {
        try {

            $client_to->validate_payment(
                currency     => $to_currency,
                amount       => $to_amount,
                payment_type => 'internal_transfer',
                rule_engine  => $rule_engine,
            );
        } catch ($err) {
            log_exception();
            my $msg = $err->{message_to_client} || localize("Transfer validation failed on [_1].", $loginid_to);
            return $error_audit_sub->("validate_payment failed for $loginid_to [$err]", $msg);
        }
    }

    my $response;
    try {
        my $remark = "Account transfer from $loginid_from to $loginid_to.";

        my %txn_details = (
            from_login                => $loginid_from,
            to_login                  => $loginid_to,
            fees                      => $fees,
            fees_percent              => $fees_percent,
            fees_currency             => $currency,
            min_fee                   => $min_fee,
            fee_calculated_by_percent => $fee_calculated_by_percent,
        );

        my $additional_remark = get_transfer_fee_remark(%txn_details);

        $remark = "$remark $additional_remark" if $additional_remark;

        my $inter_db_transfer = 0;
        if ($client_from->broker_code ne $client_to->broker_code) {
            my $db_from = BOM::Config::BrokerDatabase->get_domain($client_from->broker_code) // '';
            my $db_to   = BOM::Config::BrokerDatabase->get_domain($client_to->broker_code)   // '';

            $inter_db_transfer = $db_from eq $db_to ? 0 : 1;
        }

        $response = $client_from->payment_account_transfer(
            currency          => $currency,
            amount            => $amount,
            to_amount         => $to_amount,
            toClient          => $client_to,
            fmStaff           => $loginid_from,
            toStaff           => $loginid_to,
            remark            => $remark,
            inter_db_transfer => $inter_db_transfer,
            source            => $source,
            fees              => $fees,
            gateway_code      => 'account_transfer',
            txn_details       => \%txn_details,
        );
    } catch ($e) {
        my $err_str = (ref $e eq 'ARRAY') ? "@$e" : $e;
        my $err     = "$err_msg Account Transfer failed [$err_str]";
        log_exception();
        return $error_audit_sub->($err);
    }
    BOM::User::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], amount[$amount], curr[$currency]", $loginid_from);

    $client_from->user->daily_transfer_incr({
        amount   => $amount,
        currency => $currency
    });

    return {
        status              => 1,
        transaction_id      => $response->{transaction_id},
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to,
        accounts            => [{
                loginid      => $client_from->loginid,
                balance      => $client_from->default_account->balance,
                currency     => $client_from->default_account->currency_code,
                account_type => $client_from->get_account_type->category->name,
            },
            {
                loginid      => $client_to->loginid,
                balance      => $client_to->default_account->balance,
                currency     => $client_to->default_account->currency_code,
                account_type => $client_to->get_account_type->category->name,
            }]};
};

rpc topup_virtual => sub {
    my $params = shift;

    my ($client, $source) = @{$params}{qw/client source/};

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'TopupDemoError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    # ERROR CHECKS
    if (!$client->is_virtual) {
        return $error_sub->(localize('Sorry, this feature is available to demo accounts only'));
    }

    # CREDIT HIM WITH THE MONEY
    my ($curr, $amount) = $client->deposit_virtual_funds($source);

    return {
        amount   => $amount,
        currency => $curr
    };
};

sub _transfer_between_accounts_error {
    my ($message_to_client, $message, $override_code) = @_;
    my $error_code = (any { ($override_code // '') eq $_ } TRANSFER_OVERRIDE_ERROR_CODES->@*) ? $override_code : 'TransferBetweenAccountsError';
    return BOM::RPC::v3::Utility::create_error({
        code              => $error_code,
        message_to_client => ($message_to_client // localize('Transfers between accounts are not available for your account.')),
        ($message) ? (message => $message) : (),
    });
}

sub _validate_transfer_between_accounts {
    my ($current_client, $client_from, $client_to,     $args)        = @_;
    my ($currency,       $amount,      $from_currency, $to_currency) = @{$args}{qw/currency amount from_currency to_currency/};

    # error out if one of the client is not defined, i.e.
    # loginid provided is wrong or not in siblings
    return _transfer_between_accounts_error() if (not $client_from or not $client_to);

    my $from_currency_type = LandingCompany::Registry::get_currency_type($currency);
    my $to_currency_type   = LandingCompany::Registry::get_currency_type($to_currency);
    # These rule are checking app settings; so they should be excluded from the rule engine
    # we don't allow transfer between these two currencies
    if ($from_currency ne $to_currency) {
        my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;
        return _transfer_between_accounts_error(localize('Account transfers are not available between [_1] and [_2]', $from_currency, $to_currency))
            if first { $_ eq $from_currency or $_ eq $to_currency } @$disabled_for_transfer_currencies;
    }
    return _transfer_between_accounts_error(localize('Transfers between accounts are currently unavailable. Please try again later.'))
        if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
        and (($from_currency_type // '') ne ($to_currency_type // ''));

    my $is_daily_cumulative_limit_enabled =
        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable;
    if ($is_daily_cumulative_limit_enabled) {
        my $user_daily_transfer_amount = $current_client->user->daily_transfer_amount();
        my $max_allowed_amount         = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{max};
        return _transfer_between_accounts_error(
            localize(
                'The maximum amount of transfers is [_1] [_2] per day. Please try again tomorrow.',
                formatnumber('amount', $currency, $max_allowed_amount), $currency
            )) unless convert_currency($user_daily_transfer_amount, 'USD', $currency) + abs($amount) < $max_allowed_amount;

    } else {

        # check for internal transactions number limits
        my $daily_transfer_limit = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts;
        my $daily_transfer_count = $current_client->user->daily_transfer_count();
        return _transfer_between_accounts_error(
            localize("You can only perform up to [_1] transfers a day. Please try again tomorrow.", $daily_transfer_limit))
            unless $daily_transfer_count < $daily_transfer_limit;

        my $max_allowed_amount = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{max};

        return _transfer_between_accounts_error(
            localize(
                'Provided amount is not within permissible limits. Maximum transfer amount for [_1] currency is [_2].',
                $currency, formatnumber('amount', $currency, $max_allowed_amount))
        ) if (($amount > $max_allowed_amount) and ($from_currency_type ne $to_currency_type));
    }
    #minimum thresholds should be not affected by total limit
    my $min_allowed_amount = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{min};
    return _transfer_between_accounts_error(
        localize(
            'Provided amount is not within permissible limits. Minimum transfer amount for [_1] currency is [_2].',
            $currency, formatnumber('amount', $currency, $min_allowed_amount))) if $amount < $min_allowed_amount;

    # this check is only for svg and unauthenticated clients
    # fiat to crypto || crypto to fiat || crypto to crypto
    my $limit_field = lc(sprintf '%s_to_%s', $from_currency_type, $to_currency_type);
    if (    $current_client->landing_company->short eq 'svg'
        and not($current_client->status->age_verification or $current_client->fully_authenticated)
        and $from_currency_type =~ /^(fiat|crypto)$/
        and $to_currency_type   =~ /^(fiat|crypto)$/
        and $limit_field ne 'fiat_to_fiat')
    {
        my $limit_amount = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->$limit_field;

        $limit_amount = convert_currency($limit_amount, 'USD', $from_currency) if $from_currency ne 'USD';

        my $is_over_transfer_limit;

        # checks if the amount itself is already over the limit, skips accessing lifetime transfer amount if true
        if ($amount > $limit_amount) {

            $is_over_transfer_limit = 1;

        } else {

            my $lifetime_transfer_amount = $client_from->lifetime_internal_withdrawals();

            $is_over_transfer_limit = 1 if (($lifetime_transfer_amount + $amount) > $limit_amount);
        }

        if ($is_over_transfer_limit) {

            $current_client->status->upsert('allow_document_upload', 'system', sprintf('%s_TRANSFER_OVERLIMIT', uc($limit_field)));
            my $message_to_client = localize(
                'You have exceeded [_1] [_2] in cumulative transactions. To continue, you will need to verify your identity.',
                formatnumber('amount', $from_currency, $limit_amount),
                $from_currency
            );

            return BOM::RPC::v3::Utility::create_error({
                code              => sprintf('%s2%sTransferOverLimit', ucfirst($from_currency_type), ucfirst($to_currency_type)),
                message_to_client => $message_to_client,
            });
        }
    }

    return undef;
}

sub validate_amount {
    my ($amount, $currency) = @_;

    return localize('Invalid amount.') unless (looks_like_number($amount));

    my $num_of_decimals = Format::Util::Numbers::get_precision_config()->{amount}->{$currency};
    return localize('Invalid currency.') unless defined $num_of_decimals;
    my ($int, $precision) = Math::BigFloat->new($amount)->length();
    return localize('Invalid amount. Amount provided can not have more than [_1] decimal places.', $num_of_decimals)
        if ($precision > $num_of_decimals);

    return undef;
}

sub _validate_paymentagent_limits {
    my (%args)   = @_;
    my $currency = $args{currency};
    my $min_max  = BOM::Config::PaymentAgent::get_transfer_min_max($currency);

    my $amount    = $args{amount};
    my $error_sub = $args{error_sub};
    my $min       = $args{payment_agent}->min_withdrawal // $min_max->{minimum};
    my $max       = $args{payment_agent}->max_withdrawal // $min_max->{maximum};

    return $error_sub->(
        localize(
            'Invalid amount. Minimum is [_1], maximum is [_2].',
            formatnumber('amount', $currency, $min),
            formatnumber('amount', $currency, $max))) if ($amount < $min || $amount > $max);

    return undef;
}

sub _check_facility_availability {
    my (%args) = @_;

    # Check global status via the chronicle database
    my $app_config = BOM::Config::Runtime->instance->app_config;

    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents)
    {
        return $args{error_sub}->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'));
    }

    return undef;
}

rpc 'cashier_withdrawal_cancel', sub {
    my $params = shift;

    if (my $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, ['compliance_checks'])) {
        return $validation_error;
    }

    my ($client, $args) = @{$params}{qw/client args/};

    if (my $cashier_validation_error = BOM::RPC::v3::Utility::cashier_validation($client, 'withdraw')) {
        return $cashier_validation_error;
    }

    my $currency = $client->default_account->currency_code();

    if (LandingCompany::Registry::get_currency_type($currency) ne 'crypto') {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidRequest',
            message_to_client => localize('Crypto cashier is unavailable for fiat currencies.'),
        });
    }

    my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
    return $crypto_service->withdrawal_cancel($client->loginid, $args->{id}, $client->currency);
};

rpc 'cashier_payments', sub {
    my $params = shift;

    if (my $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, ['compliance_checks'])) {
        return $validation_error;
    }

    my ($client, $args) = @{$params}{qw/client args/};

    my $currency = $client->default_account ? $client->default_account->currency_code() : '';
    unless ($currency) {
        return BOM::RPC::v3::Utility::create_error_by_code('NoAccountCurrency');
    }
    if (LandingCompany::Registry::get_currency_type($currency) ne 'crypto') {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidRequest',
            message_to_client => localize('Crypto cashier is unavailable for fiat currencies.'),
        });
    }

    my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
    return $crypto_service->transactions($client->loginid, $args->{transaction_type}, $client->currency);
};

rpc 'crypto_config',
    auth => [],    # unauthenticated
    sub {
    my $params = shift;

    my $currency_code = $params->{args}{currency_code} // '';    #not uppercasing currency code bcs we do have currency like eUSDT.

    if ($currency_code && !BOM::Config::CurrencyConfig::is_valid_crypto_currency($currency_code)) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CryptoInvalidCurrency',
            message_to_client => localize('The provided currency [_1] is not a valid cryptocurrency.', $currency_code),
        });
    }
    my $client = ($params->{token_details}{loginid}) ? BOM::User::Client->get_client_instance($params->{token_details}{loginid}) : '';
    # Retrieve from redis
    my $result;
    my $redis_read = BOM::Config::Redis::redis_replicated_read();
    my $client_min_locked_amount;

    $result = $currency_code ? $redis_read->get(CRYPTO_CONFIG_RPC_REDIS . "::" . $currency_code) : $redis_read->get(CRYPTO_CONFIG_RPC_REDIS);
    if ($result) {
        my $decoded_result = decode_json($result);
        if ($client && $client->loginid) {
            BOM::RPC::v3::Utility::handle_client_locked_min_withdrawal_amount($decoded_result, $client->loginid, $client->currency);
        }
        return $decoded_result;
    }

    my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
    $result = $crypto_service->crypto_config($currency_code);

    unless ($result->{error}) {
        my $redis_write = BOM::Config::Redis::redis_replicated_write();
        $currency_code
            ? $redis_write->setex(CRYPTO_CONFIG_RPC_REDIS . "::" . $currency_code, 5, encode_json($result))
            : $redis_write->setex(CRYPTO_CONFIG_RPC_REDIS,                         5, encode_json($result));
        if ($client && $client->loginid) {
            BOM::RPC::v3::Utility::handle_client_locked_min_withdrawal_amount($result, $client->loginid, $client->currency);
        }
    }
    return $result;
    };

rpc 'crypto_estimations',
    auth => [],    #unauthenticated
    sub {
    my $params        = shift;
    my $currency_code = $params->{args}{currency_code} // '';

    unless ($currency_code && BOM::Config::CurrencyConfig::is_valid_crypto_currency($currency_code)) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CryptoInvalidCurrency',
            message_to_client => localize('The provided currency [_1] is not a valid cryptocurrency.', $currency_code),
        });
    }

    my $result;
    # Try to retrieve cached data from redis
    my $redis_read            = BOM::Config::Redis::redis_replicated_read();
    my $redis_key_estimations = CRYPTO_ESTIMATIONS_RPC_CACHE . "::" . $currency_code;

    $result = $redis_read->get($redis_key_estimations);
    return decode_json($result) if $result;

    my $crypto_service = BOM::Platform::CryptoCashier::API->new($params);
    $result = $crypto_service->crypto_estimations($currency_code);

    unless ($result->{error}) {
        my $redis_write = BOM::Config::Redis::redis_replicated_write();
        $redis_write->setex($redis_key_estimations, CRYPTO_ESTIMATIONS_RPC_CACHE_TTL, encode_json($result));
    }

    return $result;

    };

1;

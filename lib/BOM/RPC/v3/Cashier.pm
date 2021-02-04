package BOM::RPC::v3::Cashier;

use strict;
use warnings;

use HTML::Entities;
use List::Util qw( min first any );
use Scalar::Util qw( looks_like_number );
use Data::UUID;
use Path::Tiny;
use Date::Utility;
use Syntax::Keyword::Try;
use String::UTF8::MD5;
use LWP::UserAgent;
use Log::Any qw($log);
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use YAML::XS qw(LoadFile);
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use Format::Util::Numbers qw/formatnumber financialrounding/;
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
use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User::AuditLog;
use BOM::Platform::RiskProfile;
use BOM::Platform::Client::CashierValidation;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::RPC::v3::MT5::Account;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Transaction::Validation;
use BOM::Database::Model::HandoffToken;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::ClientDB;
use BOM::Platform::Event::Emitter;

requires_auth('wallet');

use Log::Any qw($log);

use constant MAX_DESCRIPTION_LENGTH => 250;
use constant HANDOFF_TOKEN_TTL      => 5 * 60;    # 5 Minutes

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

    # this should come before all validation as verification
    # token is mandatory for withdrawal.
    if ($action eq 'withdraw' && $type eq 'url') {
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
        $validation_error = BOM::RPC::v3::Utility::validation_checks($params->{client}, ['validate_tnc']);
        return $validation_error if $validation_error;
    }

    my $client_loginid = $client->loginid;
    my $validation     = BOM::Platform::Client::CashierValidation::validate($client_loginid, $action);
    return BOM::RPC::v3::Utility::create_error($validation->{error}) if exists $validation->{error};

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
        my %response;
        unless ($provider eq 'crypto' && $action eq 'deposit') {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidRequest',
                message_to_client => localize("Cashier API doesn't support the selected provider or operation."),
            });
        }

        return {
            action  => 'deposit',
            deposit => {
                address => BOM::RPC::v3::Utility::client_crypto_deposit_address($client),
            }};
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
        });
    }

    return $error_sub->(localize('Sorry, cashier is temporarily unavailable due to system maintenance.'))
        if BOM::Config::CurrencyConfig::is_cashier_suspended();

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $client_loginid});
    # hit DF's CreateCustomer API
    my $ua = LWP::UserAgent->new(timeout => 20);
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
                    . "Loginid: $client_loginid\n"
                    . "Doughflow response: [$errortext]");

            return $error_sub->(
                localize(
                    'Sorry, there was a problem validating your personal information with our payment processor. Please check your details and try again.'
                ),
                'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
            );
        }

        if (my @error_fields = ($errortext =~ /(province|country|city|street|pcode|phone|email)/g)) {

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

    my ($loginid, $website_name, $currency, $action, $language, $brand_name, $domain) =
        @{$args}{qw/loginid website_name currency action language brand_name domain/};

    $prefix = lc($currency) if $prefix eq 'cryptocurrency';

    BOM::User::AuditLog::log("redirecting to $prefix");

    $language = uc($language // 'EN');

    my $url = 'https://';
    if (($website_name // '') =~ /qa/) {
        $url .= 'www.' . lc($website_name) . "/cryptocurrency/$prefix";
    } else {
        my $is_white_listed = $domain && (any { $domain eq $_ } BOM::Config->domain->{white_list}->@*);
        $domain = BOM::Config->domain->{default_domain} unless $domain and $is_white_listed;
        $url .= "crypto-cashier.$domain/cryptocurrency/$prefix";
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
    $limit->{num_of_days_limit} = formatnumber('price', $currency, convert_currency($numdayslimit, $withdrawal_limit_curr, $currency));
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
        my $between_accounts_transfer_limit =
            BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts;
        my $mt5_transfer_limits     = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5;
        my $user_internal_transfers = $client->user->daily_transfer_count();
        my $user_mt5_transfers      = $client->user->daily_transfer_count('mt5');

        my $available_internal_transfer = $between_accounts_transfer_limit - $user_internal_transfers;
        my $available_mt5_transfer      = $mt5_transfer_limits - $user_mt5_transfers;

        $limit->{daily_transfers} = {
            'internal' => {
                allowed   => $between_accounts_transfer_limit,
                available => $available_internal_transfer > 0 ? $available_internal_transfer : 0,
            },
            'mt5' => {
                allowed   => $mt5_transfer_limits,
                available => $available_mt5_transfer > 0 ? $available_mt5_transfer : 0
            }};
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
    my $available_payment_agents = _get_available_payment_agents($target_country, $broker_code, $currency, $loginid, 1);

    my $payment_agent_table_row = [];
    foreach my $loginid (keys %{$available_payment_agents}) {
        my $payment_agent = $available_payment_agents->{$loginid};
        my $currency      = $payment_agent->{currency_code};

        my $min_max;
        try {
            $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);
        } catch {
            log_exception();
            $log->warnf('%s dropped from PA list. Failed to retrieve limits: %s', $loginid, $@);
            next;
        }

        push @{$payment_agent_table_row},
            {
            'paymentagent_loginid'  => $loginid,
            'name'                  => $payment_agent->{payment_agent_name},
            'summary'               => $payment_agent->{summary},
            'url'                   => $payment_agent->{url},
            'email'                 => $payment_agent->{email},
            'telephone'             => $payment_agent->{phone},
            'currencies'            => $currency,
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

    my $rpc_error = _check_facility_availability(error_sub => $error_sub);
    return $rpc_error if $rpc_error;

    # This uses the broker_code field to access landing_companies.yml
    return $error_sub->(localize('The payment agent facility is not available for this account.'))
        unless $client_fm->landing_company->allows_payment_agents;

    # Reads fiat/crypto from landing_companies.yml, then gets min/max from paymentagent_config.yml
    my ($payment_agent, $paymentagent_error);
    try {
        $payment_agent = BOM::User::Client::PaymentAgent->new({
            'loginid'    => $loginid_fm,
            db_operation => 'replica'
        });
    } catch {
        log_exception();
        $paymentagent_error = $@;
    }
    if ($paymentagent_error or not $payment_agent) {
        return $error_sub->(localize('You are not authorized for transfers via payment agents.'));
    }

    $rpc_error = _validate_paymentagent_limits(
        error_sub     => $error_sub,
        payment_agent => $payment_agent,
        pa_loginid    => $client_fm->loginid,
        amount        => $amount,
        currency      => $currency
    );

    return $rpc_error if $rpc_error;

    my $client_to = eval { BOM::User::Client->new({loginid => $loginid_to, db_operation => 'write'}) }
        or return $error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to));

    return $error_sub->(localize('Payment agent transfers are not allowed for the specified accounts.'))
        if ($client_fm->landing_company->short ne $client_to->landing_company->short);

    if (my @missing_requirements = $client_fm->missing_requirements('withdrawal')) {
        return BOM::RPC::v3::Utility::missing_details_error(details => \@missing_requirements);
    }

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

    if ($args->{dry_run}) {
        return {
            status              => 2,
            client_to_full_name => $client_to->full_name,
            client_to_loginid   => $client_to->loginid
        };
    }

    my $validation_fm = BOM::Platform::Client::CashierValidation::validate($loginid_fm, 'withdraw');
    my $validation_to = BOM::Platform::Client::CashierValidation::validate($loginid_to, 'deposit');
    if (exists $validation_to->{error}) {
        # to_clinet's data should not be visible for who is transferring so the error message is replaced by a general one unless for sepcific messages
        my $msg = localize('You cannot transfer to account [_1]', $loginid_to);
        $msg .= localize(', as their cashier is locked.')   if $validation_to->{error}->{message_to_client} eq 'Your cashier is locked.';
        $msg .= localize(', as their account is disabled.') if $validation_to->{error}->{message_to_client} eq 'Your account is disabled.';
        $msg .= localize(', as their verification documents have expired.')
            if $validation_to->{error}->{message_to_client} =~ /Your identity documents have expired/;
        $validation_to->{error}->{message_to_client} = $msg;
    }
    my $validation = $validation_fm // $validation_to;
    if (exists $validation->{error}) {
        $validation->{error}->{code} = 'PaymentAgentTransferError';
        return BOM::RPC::v3::Utility::create_error($validation->{error});
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
        . " ($loginid_fm)"
        . " to $loginid_to. Transaction reference: $reference. Timestamp: $today."
        . ($description ? " Agent note: $description" : '');

    ## We want to pass limits in to the function so it can verify amounts
    my $lcshort              = $client_fm->landing_company->short;
    my $lc_withdrawal_limits = BOM::Config::payment_limits()->{withdrawal_limits}->{$lcshort};
    my ($lc_lifetime_limit, $lc_for_days, $lc_limit_for_days, $lc_currency) =
        @$lc_withdrawal_limits{qw/ lifetime_limit for_days limit_for_days currency/};
    ## For some landing companies, we only check the lifetime limits. Thus, we set limit_for_days to 0:
    if ($client_fm->landing_company->lifetime_withdrawal_limit_check) {
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
    } catch {
        log_exception();
        $error = $@;
    }

    if ($error) {
        if (ref $error ne 'ARRAY') {
            return $error_sub->(localize("Sorry, an error occurred whilst processing your request."));
        }

        my ($error_code, $error_msg) = @$error;
        my $full_error_msg = "Paymentagent Transfer failed to $loginid_to [$error_msg]";

        if ($error_code eq 'BI102') {
            return $error_sub->(localize('Request too frequent. Please try again later.'));
        } elsif ($error_code eq 'BI204') {
            return $error_sub->(localize('Payment agent transfers are not allowed within the same account.'));
        } elsif ($error_code eq 'BI205') {    ## Redundant check (should be caught earlier by something else)
            ## Same template for two cases
            return $error_sub->(localize('Login ID ([_1]) does not exist.', $error_msg =~ /\b$loginid_fm\b/ ? $loginid_fm : $loginid_to));
        } elsif ($error_code eq 'BI206') {    ## Redundant check (account is virtual)
            return $error_sub->(localize('Sorry, this feature is not available.'), $full_error_msg);
        } elsif ($error_code eq 'BI213') {
            return $error_sub->(localize("We are unable to transfer to [_1], because that account has been restricted.", $loginid_to));
        } elsif ($error_code eq 'BI214') {
            return $error_sub->(localize('You cannot perform this action, as your verification documents have expired.'));
        } elsif ($error_code eq 'BI215') {
            return $error_sub->(localize('You cannot transfer to account [_1], as their verification documents have expired.', $loginid_to));
        } elsif ($error_code eq 'BI216') {    ## Redundant check
            return $error_sub->(localize('You are not authorized for transfers via payment agents.'));
        } elsif ($error_code eq 'BI217') {
            return $error_sub->(localize('Your account needs to be authenticated to perform payment agent transfers.'));
        } elsif ($error_code eq 'BI218') {
            return $error_sub->(
                localize(
                    'You cannot perform this action, as [_1] is not the default account currency for payment agent [_2].', $currency,
                    $payment_agent->client_loginid
                ));
        } elsif ($error_code eq 'BI219') {
            return $error_sub->(
                localize('You cannot perform this action, as [_1] is not the default account currency for client [_2].', $currency, $loginid_fm));
        } elsif ($error_code eq 'BI220') {
            return $error_sub->(
                localize('You cannot perform this action, as [_1] is not the default account currency for client [_2].', $currency, $loginid_to));
        } elsif ($error_code eq 'BI221') {
            my $error_detail = _get_json_error($error_msg);
            return $error_sub->(
                localize(
                    'Withdrawal is [_2] [_1] but balance [_3] includes frozen bonus [_4].',
                    $currency,
                    $error_detail->{amount},
                    $error_detail->{balance},
                    $error_detail->{bonus}));
        } elsif ($error_code eq 'BI222') {
            my $error_detail = _get_json_error($error_msg);

            ## If the amount left is non-negative, we show exactly how much at the end of the message
            return $error_sub->(
                localize(
                    'Sorry, you cannot withdraw. Your withdrawal amount [_1] exceeds withdrawal limit[_2].',
                    "$error_detail->{amount} $currency",
                    $error_detail->{limit_left} <= 0 ? '' : " $error_detail->{limit_left} $currency"
                ));
        } elsif ($error_code eq 'BI223') {
            my $error_detail = _get_json_error($error_msg);

            return $error_sub->(localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $error_detail->{balance}, $currency));
        } else {
            $log->fatal("Unexpected DB error: $full_error_msg");
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

    my $name  = $client_to->first_name;
    my $title = localize("We've completed a transfer");
    send_email({
        to                    => $client_to->email,
        subject               => localize('Acknowledgement of Money Transfer'),
        template_name         => 'pa_transfer_confirm',
        template_args         => _template_args($website_name, $client_to, $client_fm, $amount, $currency, $name, $title),
        use_email_template    => 1,
        email_content_is_html => 1,
        use_event             => 1,
        template_loginid      => $loginid_to
    });

    return {
        status              => 1,
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to,
        transaction_id      => $response->{transaction_id}};
};

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

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

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

    # 2018/05/04: Currently this check is irrelevent, because only CR clients can use payment agents, and they
    #   aren't required to accept T&Cs. It's here in case either of these situations change.
    return $error_sub->(localize('Terms and conditions approval is required.')) if $client->is_tnc_approval_required;

    my $amount_validation_error = validate_amount($amount, $currency);
    return $error_sub->($amount_validation_error) if $amount_validation_error;

    my $rpc_error = _check_facility_availability(error_sub => $error_sub);
    return $rpc_error if $rpc_error;

    return $error_sub->(localize('Payment agent facilities are not available for this account.'))
        unless $client->landing_company->allows_payment_agents;

    return $error_sub->(localize('You are not authorized for withdrawals via payment agents.'))
        unless ($source_bypass_verification or BOM::Transaction::Validation->new({clients => [$client]})->allow_paymentagent_withdrawal($client));

    my $validation = BOM::Platform::Client::CashierValidation::validate($client_loginid, 'withdraw');
    return BOM::RPC::v3::Utility::create_error($validation->{error}) if exists $validation->{error};

    return $error_sub->(localize('You cannot withdraw funds to the same account.')) if $client_loginid eq $paymentagent_loginid;

    return $error_sub->(localize('You cannot perform this action, please set your residence.')) unless $client->residence;

    my ($paymentagent, $paymentagent_error);
    try {
        $paymentagent = BOM::User::Client::PaymentAgent->new({
            'loginid'    => $paymentagent_loginid,
            db_operation => 'replica'
        });
    } catch {
        log_exception();
        $paymentagent_error = $@;
    }
    if ($paymentagent_error or not $paymentagent) {
        return $error_sub->(localize('Please enter a valid payment agent ID.'));
    }

    my $pa_client = $paymentagent->client;
    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is not authorized.", $pa_client->loginid))
        unless $paymentagent->is_authenticated;

    return $error_sub->(localize('Payment agent withdrawals are not allowed for specified accounts.'))
        if ($client->broker ne $paymentagent->broker);

    return $error_sub->(
        localize('You cannot perform this action, as [_1] is not default currency for your account [_2].', $currency, $client->loginid))
        if ($client->currency ne $currency or not $client->default_account);

    return $error_sub->(
        localize("You cannot perform this action, as [_1] is not default currency for payment agent account [_2].", $currency, $pa_client->loginid))
        if ($pa_client->currency ne $currency or not $pa_client->default_account);

    $rpc_error = _validate_paymentagent_limits(
        error_sub     => $error_sub,
        payment_agent => $paymentagent,
        pa_loginid    => $pa_client->loginid,
        amount        => $amount,
        currency      => $currency
    );
    return $rpc_error if $rpc_error;

    # check that the additional information does not exceeded the allowed limits
    return $error_sub->(localize('Further instructions must not exceed [_1] characters.', MAX_DESCRIPTION_LENGTH))
        if (length($further_instruction) > MAX_DESCRIPTION_LENGTH);

    # check that both the client payment agent cashier is not locked
    return $error_sub->(localize('Your account cashier is locked. Please contact us for more information.')) if $client->status->cashier_locked;

    if (my @missing_requirements = $client->missing_requirements('withdrawal')) {
        return BOM::RPC::v3::Utility::missing_details_error(details => \@missing_requirements);
    }

    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is disabled.", $pa_client->loginid))
        if $pa_client->status->disabled;

    return $error_sub->(localize("We cannot transfer to account [_1]. Please select another payment agent.", $pa_client->loginid))
        if $pa_client->status->unwelcome;

    return $error_sub->(localize("You cannot perform the withdrawal to account [_1], as the payment agent's cashier is locked.", $pa_client->loginid))
        if $pa_client->status->cashier_locked;

    return $error_sub->(
        localize("You cannot perform withdrawal to account [_1], as payment agent's verification documents have expired.", $pa_client->loginid))
        if $pa_client->documents_expired;

    #lets make sure that client is withdrawing to payment agent having allowed countries.
    my $pa_target_countries = $paymentagent->get_countries;
    my $is_country_allowed  = any { $client->residence eq $_ } @$pa_target_countries;
    my $email_marketing     = request()->brand->emails('marketing');
    return $error_sub->(
        localize(
            "We're unable to process this withdrawal because your country of residence is not within the payment agent's portfolio. Please contact [_1] for more info.",
            $email_marketing
        )) if (not $is_country_allowed and not _is_pa_residence_exclusion($pa_client));

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

    my $withdraw_error;
    try {
        $client->validate_payment(
            currency => $currency,
            amount   => -$amount,    #withdraw action use negative amount
        );
    } catch {
        log_exception();
        $withdraw_error = $@;
    }

    if ($withdraw_error) {
        return $error_sub->(
            __client_withdrawal_notes({
                    client => $client,
                    amount => $amount,
                    error  => $withdraw_error
                }));
    }

    my $day              = Date::Utility->new->is_a_weekend ? 'weekend' : 'weekday';
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
    } catch {
        log_exception();
        $error = $@;
    }

    if ($error) {
        if (ref $error ne 'ARRAY') {
            return $error_sub->(localize("Sorry, an error occurred whilst processing your request."));
        }

        my ($error_code, $error_msg) = @$error;
        my $full_error_msg = "Paymentagent Withdraw failed to $paymentagent_loginid [$error_msg]";
        # too many attempts
        if ($error_code eq 'BI102') {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $full_error_msg);
        } else {
            $log->fatal("Unexpected DB error: $full_error_msg");
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
                $full_error_msg);
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

    my $name  = $pa_client->first_name;
    my $title = localize("You have received funds");
    send_email({
        to                    => $paymentagent->email,
        subject               => localize('You have received funds'),
        template_name         => 'pa_withdraw_confirm',
        template_args         => _template_args($website_name, $client, $pa_client, $amount, $currency, $name, $title),
        use_email_template    => 1,
        email_content_is_html => 1,
        use_event             => 1,
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
        return (localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $balance, $currency));
    } elsif ($error =~ /exceeds withdrawal limit \[(.+)\]/) {
        # if limit <= 0, we show: Your withdrawal amount 100.00 USD exceeds withdrawal limit.
        # if limit > 0, we show: Your withdrawal amount 100.00 USD exceeds withdrawal limit USD 20.00.
        my $limit = " $1";
        if ($limit =~ /0\.00\s+$/ or $limit =~ /\d+\.\d+-\s+$/) {
            $limit = '';
        }

        return localize('Sorry, you cannot withdraw. Your withdrawal amount [_1] exceeds withdrawal limit[_2].', "$amount $currency", $limit);
    } elsif (my (@limits) = $error =~ /reached the  maximum withdrawal limit of \[(\d+(\.\d+)?) ([A-Z]+)\]/) {
        return localize("You've reached the maximum withdrawal limit of [_1] [_2]. Please authenticate your account to make unlimited withdrawals.",
            $limits[0], $limits[1]);
    }

    my $withdrawal_limits = $client->get_withdrawal_limits();

    # At this point, the Client is not allowed to withdraw. Return error message.
    my $error_message = $error;

    if ($withdrawal_limits->{'frozen_free_gift'} > 0) {
        # Insert turnover limit as a parameter depends on the promocode type
        $error_message .= ' '
            . localize(
            'Note: You will be able to withdraw your bonus of [_2] [_1] only once your aggregate volume of trades exceeds [_3] [_1]. This restriction applies only to the bonus and profits derived therefrom.  All other deposits and profits derived therefrom can be withdrawn at any time.',
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
    my $status = $client->status;

    if (BOM::Config::CurrencyConfig::is_payment_suspended()) {
        return _transfer_between_accounts_error(localize('Payments are suspended.'));
    }

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual && $token_type ne 'oauth_token';

    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is currently disabled.'))
        if $status->disabled;

    my $siblings = $client->real_account_siblings_information(include_disabled => 0);

    my ($loginid_from, $loginid_to) = @{$args}{qw/account_from account_to/};

    my @accounts;
    foreach my $cl (values %$siblings) {
        push @accounts,
            {
            loginid      => $cl->{loginid},
            balance      => $cl->{balance},
            currency     => $cl->{currency},
            account_type => 'binary',
            };
    }

    # just return accounts list if loginid from or to is not provided
    if (not $loginid_from or not $loginid_to) {
        if (($args->{accounts} // '') eq 'all' and not(BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all)) {
            my @mt5_accounts = BOM::RPC::v3::MT5::Account::get_mt5_logins($client)->else(sub { return Future->done(); })->get;
            for my $mt5_acc (grep { not $_->{error} and $_->{group} !~ /^demo/ } @mt5_accounts) {
                push @accounts,
                    {
                    loginid      => $mt5_acc->{login},
                    balance      => $mt5_acc->{display_balance},
                    account_type => 'mt5',
                    mt5_group    => $mt5_acc->{group},
                    currency     => $mt5_acc->{currency}};
            }
        }

        return {
            status   => 0,
            accounts => \@accounts
        };
    }
    my @mt5_logins          = $client->user->get_mt5_loginids();
    my $is_mt5_loginid_from = any { $loginid_from eq $_ } @mt5_logins;
    my $is_mt5_loginid_to   = any { $loginid_to eq $_ } @mt5_logins;

    # Both $loginid_from and $loginid_to must be either a real or a MT5 account
    # Unfortunately demo MT5 accounts will slip through this check, but they will
    # be caught in one of the BOM::RPC::v3::MT5::Account functions
    return BOM::RPC::v3::Utility::permission_error()
        unless ((
            exists $siblings->{$loginid_from}
            or $is_mt5_loginid_from
        )
        and (exists $siblings->{$loginid_to}
            or $is_mt5_loginid_to));

    return _transfer_between_accounts_error(localize('Transfer between two MT5 accounts is not allowed.'))
        if ($is_mt5_loginid_from and $is_mt5_loginid_to);

    # create client from siblings so that we are sure that from and to loginid
    # provided are for same user
    my ($client_from, $client_to, $res);
    try {
        $client_from = BOM::User::Client->new({loginid => $siblings->{$loginid_from}->{loginid}}) if (!$is_mt5_loginid_from);
        $client_to   = BOM::User::Client->new({loginid => $siblings->{$loginid_to}->{loginid}})   if (!$is_mt5_loginid_to);
    } catch {
        log_exception();
        $res = _transfer_between_accounts_error();
    }
    return $res if $res;

    return _transfer_between_accounts_error(localize('Your account cashier is locked. Please contact us for more information.'))
        if (($client_from && $client_from->status->cashier_locked) or ($client_to && $client_to->status->cashier_locked));
    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is withdrawal locked.'))
        if ($client_from && ($client_from->status->withdrawal_locked || $client_from->status->no_withdrawal_or_trading));
    if ($client_from) {
        if (my @missed_fields = $client_from->missing_requirements('withdrawal')) {
            return BOM::RPC::v3::Utility::missing_details_error(details => \@missed_fields);
        }
    }
    return _transfer_between_accounts_error(localize('Please provide valid currency.')) unless $currency;
    return _transfer_between_accounts_error(localize('Please provide valid amount.'))
        if (not looks_like_number($amount) or $amount <= 0);

    my $transfers_blocked_err = localize("Transfers are not allowed for these accounts.");

    # this transfer involves an MT5 account
    if ($is_mt5_loginid_from or $is_mt5_loginid_to) {
        delete @{$params->{args}}{qw/account_from account_to/};

        my ($method, $binary_login, $mt5_login);

        if ($is_mt5_loginid_to) {

            return _transfer_between_accounts_error(localize('From account provided should be same as current authorized client.'))
                unless ($client->loginid eq $loginid_from)
                or $token_type eq 'oauth_token';

            return _transfer_between_accounts_error(localize('Currency provided is different from account currency.'))
                if ($siblings->{$loginid_from}->{currency} ne $currency);

            $method = \&BOM::RPC::v3::MT5::Account::mt5_deposit;
            $params->{args}{from_binary} = $binary_login = $loginid_from;
            $params->{args}{to_mt5}      = $mt5_login    = $loginid_to;
            $params->{args}{return_mt5_details} = 1;    # to get MT5 account holder name
        }

        if ($is_mt5_loginid_from) {

            return _transfer_between_accounts_error(localize('To account provided should be same as current authorized client.'))
                unless ($client->loginid eq $loginid_to)
                or $token_type eq 'oauth_token';

            $method = \&BOM::RPC::v3::MT5::Account::mt5_withdrawal;
            $params->{args}{to_binary} = $binary_login = $loginid_to;
            $params->{args}{from_mt5}  = $mt5_login    = $loginid_from;
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

                my $binary_account = BOM::User::Client->new({loginid => $binary_login})->default_account;
                push @{$resp->{accounts}},
                    {
                    loginid      => $binary_login,
                    balance      => $binary_account->balance,
                    currency     => $binary_account->currency_code,
                    account_type => 'binary',
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
                            account_type => 'mt5',
                            mt5_group    => $setting->{group},
                            }
                            unless $setting->{error};
                        return Future->done($resp);
                    });
            }
        )->catch(
            sub {
                my $err = shift;
                log_exception();
                return Future->done(_transfer_between_accounts_error($err->{error}->{message_to_client}));
            })->get;
    }

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
            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $from_currency, $to_currency, $client_from, $client_to);
    } catch {
        my $err = $@;
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

    try {
        $client_from->validate_payment(
            currency          => $currency,
            amount            => -1 * $amount,
            internal_transfer => 1,
        ) || die "validate_payment [$loginid_from]";
    } catch {
        my $err = $@;
        log_exception();

        my $limit;
        if ($err =~ /exceeds client balance/) {
            $limit = $currency . ' ' . formatnumber('amount', $currency, $client_from->default_account->balance);
        } elsif ($err =~ /includes frozen bonus \[(.+)\]/) {
            my $frozen_bonus = $1;
            $limit = $currency . ' ' . formatnumber('amount', $currency, $client_from->default_account->balance - $frozen_bonus);
        } elsif ($err =~ /exceeds withdrawal limit \[(.+)\](?:\((.+)\)\s+)?/) {

            my $bal_1 = $1;
            my $bal_2 = $2;
            $limit = $bal_1;
            if ($bal_1 =~ /^([a-zA-Z0-9]{2,20})\s+/ and $1 ne $currency) {
                $limit .= " ($bal_2)";
            }
        }

        my $msg = (defined $limit) ? localize("The maximum amount you may transfer is: [_1].", $limit) : '';
        $msg = $transfers_blocked_err if $err =~ m/transfers are not allowed/i;
        $msg = $err                   if $err =~ m/Your identity documents have expired/i;
        return $error_audit_sub->("validate_payment failed for $loginid_from [$err]", $msg);
    }

    try {
        $client_to->validate_payment(
            currency          => $to_currency,
            amount            => $to_amount,
            internal_transfer => 1,
        ) || die "validate_payment [$loginid_to]";
    } catch {
        my $err = $@;
        log_exception();

        my $msg = localize("Transfer validation failed on [_1].", $loginid_to);
        $msg = localize("Your account balance will exceed set limits. Please specify a lower amount.")
            if ($err =~ /Balance would exceed limit/);
        $msg = $transfers_blocked_err if $err =~ m/transfers are not allowed/i;
        $msg = $err                   if $err =~ m/Your identity documents have expired/i;
        return $error_audit_sub->("validate_payment failed for $loginid_to [$err]", $msg);
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
            txn_details       => \%txn_details,
        );
    } catch {
        my $err_str = (ref $@ eq 'ARRAY') ? "@$@" : $@;
        my $err     = "$err_msg Account Transfer failed [$err_str]";
        log_exception();
        return $error_audit_sub->($err);
    }
    BOM::User::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], amount[$amount], curr[$currency]", $loginid_from);

    $client_from->user->daily_transfer_incr();

    return {
        status              => 1,
        transaction_id      => $response->{transaction_id},
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to,
        accounts            => [{
                loginid      => $client_from->loginid,
                balance      => $client_from->default_account->balance,
                currency     => $client_from->default_account->currency_code,
                account_type => 'binary',
            },
            {
                loginid      => $client_to->loginid,
                balance      => $client_to->default_account->balance,
                currency     => $client_to->default_account->currency_code,
                account_type => 'binary',
            }]};
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

    # CREDIT HIM WITH THE MONEY
    my ($curr, $amount) = $client->deposit_virtual_funds($source, localize('Reset to default virtual money account balance.'));

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
    my ($current_client, $client_from, $client_to, $args, $token_type) = @_;
    # error out if one of the client is not defined, i.e.
    # loginid provided is wrong or not in siblings
    return _transfer_between_accounts_error() if (not $client_from or not $client_to);

    return BOM::RPC::v3::Utility::permission_error() if ($client_from->is_virtual or $client_to->is_virtual);

    # error out if from and to loginid are same
    return _transfer_between_accounts_error(localize('Account transfers are not available within same account.'))
        unless ($client_from->loginid ne $client_to->loginid);
    # error out if current logged in client and loginid from passed are not same
    return _transfer_between_accounts_error(localize('From account provided should be same as current authorized client.'))
        unless ($current_client->loginid eq $client_from->loginid)
        or $token_type eq 'oauth_token';

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
        localize("We are unable to transfer to [_1] because that account has been restricted.", $client_to->loginid))
        if $client_to->status->unwelcome;

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

    # we don't allow transfer between these two currencies
    if ($from_currency ne $to_currency) {
        my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;
        return _transfer_between_accounts_error(localize('Account transfers are not available between [_1] and [_2]', $from_currency, $to_currency))
            if first { $_ eq $from_currency or $_ eq $to_currency } @$disabled_for_transfer_currencies;
    }

    my $err = validate_amount($amount, $currency);
    return _transfer_between_accounts_error($err) if $err;

    my $to_currency_type = LandingCompany::Registry::get_currency_type($to_currency);

    # we don't allow fiat to fiat if they are different currency
    # this only happens when there is an internal transfer between MLT to MF, we only allow same currency transfer
    return _transfer_between_accounts_error(localize('Account transfers are not available for accounts with different currencies.'))
        if (($from_currency_type eq $to_currency_type)
        and ($from_currency_type eq 'fiat')
        and ($currency ne $to_currency));

    return _transfer_between_accounts_error(localize('Transfers between fiat and crypto accounts are currently unavailable. Please try again later.'))
        if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
        and (($from_currency_type // '') ne ($to_currency_type // ''));

    # we don't allow crypto to crypto transfer
    return _transfer_between_accounts_error(localize('Account transfers are not available within accounts with cryptocurrency as default currency.'))
        if (($from_currency_type eq $to_currency_type)
        and ($from_currency_type eq 'crypto'));

    # check for exchange rates offer
    my $crypto_currency = $from_currency_type eq 'crypto' ? $from_currency : $to_currency;
    unless ($from_currency eq $to_currency || offer_to_clients($crypto_currency)) {
        stats_event(
            'Exchange Rates Issue - No offering to clients',
            'Please inform Quants and Backend Teams to check the exchange_rates for the currency.',
            {
                alert_type => 'warning',
                tags       => ['currency:' . $crypto_currency . '_USD']});
        return _transfer_between_accounts_error(localize('Sorry, transfers are currently unavailable. Please try again later.'));
    }

    return _transfer_between_accounts_error(localize("Transfers are not allowed for these accounts."))
        if (($client_from->status->transfers_blocked || $client_to->status->transfers_blocked) && $from_currency_type ne $to_currency_type);

    # check for internal transactions number limits
    my $daily_transfer_limit = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts;
    my $daily_transfer_count = $current_client->user->daily_transfer_count();
    return _transfer_between_accounts_error(
        localize("You can only perform up to [_1] transfers a day. Please try again tomorrow.", $daily_transfer_limit))
        unless $daily_transfer_count < $daily_transfer_limit;

    my $min_allowed_amount = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{min};

    return _transfer_between_accounts_error(
        localize(
            'Provided amount is not within permissible limits. Minimum transfer amount for [_1] currency is [_2].',
            $currency, formatnumber('amount', $currency, $min_allowed_amount))) if $amount < $min_allowed_amount;

    my $max_allowed_amount = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{$currency}->{max};

    return _transfer_between_accounts_error(
        localize(
            'Provided amount is not within permissible limits. Maximum transfer amount for [_1] currency is [_2].',
            $currency, formatnumber('amount', $currency, $max_allowed_amount))
    ) if (($amount > $max_allowed_amount) and ($from_currency_type ne $to_currency_type));

    # this check is only for svg and unauthenticated clients
    if (    $current_client->landing_company->short eq 'svg'
        and not($current_client->status->age_verification or $current_client->fully_authenticated)
        and $from_currency_type eq 'fiat'
        and $to_currency_type eq 'crypto')
    {
        my $limit_amount = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->fiat_to_crypto;

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

            $current_client->status->setnx('allow_document_upload', 'system', 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT');

            my $message_to_client = localize(
                'You have exceeded [_1] [_2] in cumulative transactions. To continue, you will need to verify your identity.',
                formatnumber('amount', $from_currency, $limit_amount),
                $from_currency
            );

            return BOM::RPC::v3::Utility::create_error({
                code              => 'Fiat2CryptoTransferOverLimit',
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

sub _template_args {
    my ($website_name, $client, $pa_client, $amount, $currency, $name, $title) = @_;

    my $client_name = $client->first_name . ' ' . $client->last_name;

    return {
        website_name      => $website_name,
        amount            => $amount,
        currency          => $currency,
        client_loginid    => $client->loginid,
        name              => $name,
        title             => $title,
        client_name       => encode_entities($client_name),
        client_salutation => encode_entities($client->salutation),
        client_first_name => encode_entities($client->first_name),
        client_last_name  => encode_entities($client->last_name),
        pa_loginid        => $pa_client->loginid,
        pa_name           => encode_entities($pa_client->payment_agent->payment_agent_name),
        pa_salutation     => encode_entities($pa_client->salutation),
        pa_first_name     => encode_entities($pa_client->first_name),
        pa_last_name      => encode_entities($pa_client->last_name),
    };
}

1;

package BOM::RPC::v3::Cashier;

use strict;
use warnings;

use HTML::Entities;
use List::Util qw( min first );
use Scalar::Util qw( looks_like_number );
use Data::UUID;
use Path::Tiny;
use DateTime;
use Date::Utility;
use Try::Tiny;
use String::UTF8::MD5;
use LWP::UserAgent;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use YAML::XS qw(LoadFile);
use Scope::Guard qw/guard/;
use DataDog::DogStatsd::Helper qw(stats_inc);
use Format::Util::Numbers qw/formatnumber financialrounding/;

use Brands;
use Client::Account;
use LandingCompany::Registry;
use Client::Account::PaymentAgent;
use Postgres::FeedDB::CurrencyConverter qw/amount_from_to_currency/;

use BOM::MarketData qw(create_underlying);
use BOM::Platform::User;
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook get_doughflow_language_code_for );
use BOM::Platform::Runtime;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Config;
use BOM::Platform::AuditLog;
use BOM::Platform::RiskProfile;
use BOM::Platform::Client::CashierValidation;
use BOM::Platform::PaymentNotificationQueue;
use BOM::RPC::v3::Utility;
use BOM::Transaction::Validation;
use BOM::Database::Model::HandoffToken;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::ClientDB;
use Quant::Framework;

my $payment_limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'));

sub cashier {
    my $params = shift;

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
    }

    my $client_loginid = $client->loginid;
    my $validation = BOM::Platform::Client::CashierValidation::validate($client_loginid, $action);
    return BOM::RPC::v3::Utility::create_error({
            code              => $validation->{error}->{code},
            message_to_client => $validation->{error}->{message_to_client}}) if exists $validation->{error};

    my ($brand, $currency) = (Brands->new(name => request()->brand), $client->default_account->currency_code);
    ## if cashier provider == 'epg', we'll return epg url
    if ($provider eq 'epg') {
        return _get_epg_cashier_url($client->loginid, $params->{website_name}, $currency, $action, $params->{language}, $brand->name);
    }

    ## if currency is a cryptocurrency, use cryptocurrency cashier
    if (LandingCompany::Registry::get('costarica')->legal_allowed_currencies->{$currency} eq 'crypto') {
        return _get_cryptocurrency_cashier_url($client->loginid, $params->{website_name}, $currency, $action, $params->{language}, $brand->name);
    }

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $client_loginid});
    # hit DF's CreateCustomer API
    my $ua = LWP::UserAgent->new(timeout => 20);
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE
    );    #temporarily disable host verification as full ssl certificate chain is not available in doughflow.

    my $doughflow_loc     = BOM::Platform::Config::third_party->{doughflow}->{$brand->name};
    my $doughflow_pass    = BOM::Platform::Config::third_party->{doughflow}->{passcode};
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
    BOM::Platform::AuditLog::log('redirecting to doughflow', $df_client->loginid);
    return $url;
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
            expires        => time + 60,
        },
    );
    $handoff_token->save;

    return $handoff_token->key;
}

sub _get_epg_cashier_url {
    return _get_cashier_url('epg', @_);
}

sub _get_cryptocurrency_cashier_url {
    return _get_cashier_url('cryptocurrency', @_);
}

sub _get_cashier_url {
    my ($prefix, $loginid, $website_name, $currency, $action, $language, $brand_name) = @_;

    $prefix = lc($currency) if $prefix eq 'cryptocurrency';

    BOM::Platform::AuditLog::log("redirecting to $prefix");

    $language = uc($language // 'EN');

    my $url = 'https://';
    if (($website_name // '') =~ /qa/) {
        if ($prefix eq 'epg') {
            $url .= 'www.' . lc($website_name) . "/$prefix";
        } else {
            $url .= 'www.' . lc($website_name) . "/cryptocurrency/$prefix";
        }
    } else {
        if ($prefix eq 'epg') {
            $url .= "$prefix.binary.com/$prefix";
        } else {
            $url .= "cryptocurrency.binary.com/cryptocurrency/$prefix";
        }
    }

    $url .=
        "/handshake?token=" . _get_handoff_token_key($loginid) . "&loginid=$loginid&currency=$currency&action=$action&l=$language&brand=$brand_name";

    return $url;
}

sub get_limits {
    my $params = shift;

    my $client = $params->{client};
    if ($client->is_virtual) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'FeatureNotAvailable',
                message_to_client => localize('Sorry, this feature is not available.')});
    }

    my $landing_company = LandingCompany::Registry::get_by_broker($client->broker)->short;
    my ($wl_config, $currency) = ($payment_limits->{withdrawal_limits}->{$landing_company}, $client->currency);

    my $op_limits = BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit};
    my $open_positions_payout_per_symbol_limit;

    # For malta landing company, we only allowed volatility indices. But this limit only applied to financial instruments,
    # so skipping it here.
    if ($landing_company ne 'malta') {
        $open_positions_payout_per_symbol_limit = {
            non_atm => {
                less_than_seven_days => formatnumber('price', $currency, $op_limits->{non_atm}{less_than_seven_days}{$currency}),
                more_than_seven_days => formatnumber('price', $currency, $op_limits->{non_atm}{more_than_seven_days}{$currency}),
            },
            ($landing_company =~ /japan/) ? () : (atm => formatnumber('price', $currency, $op_limits->{atm}{$currency})),
        };
    }

    my $limit = +{
        account_balance => formatnumber('amount', $currency, $client->get_limit_for_account_balance),
        payout          => formatnumber('price',  $currency, $client->get_limit_for_payout),
        $open_positions_payout_per_symbol_limit ? (payout_per_symbol => $open_positions_payout_per_symbol_limit) : (),
        open_positions                      => $client->get_limit_for_open_positions,
        payout_per_symbol_and_contract_type => formatnumber(
            'price', $currency, BOM::Platform::Config::quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit}->{$currency}
        ),
    };

    $limit->{market_specific} = BOM::Platform::RiskProfile::get_current_profile_definitions($client);

    my $numdays       = $wl_config->{for_days};
    my $numdayslimit  = $wl_config->{limit_for_days};
    my $lifetimelimit = $wl_config->{lifetime_limit};

    if ($client->client_fully_authenticated) {
        $numdayslimit  = 99999999;
        $lifetimelimit = 99999999;
    }

    my $withdrawal_limit_curr;
    if (first { $client->landing_company->short eq $_ } ('costarica', 'japan')) {
        $withdrawal_limit_curr = $currency;
    } else {
        # limit in EUR for: MX, MLT, MF
        $withdrawal_limit_curr = 'EUR';
    }

    $limit->{num_of_days}       = $numdays;
    $limit->{num_of_days_limit} = $numdayslimit;
    $limit->{lifetime_limit}    = formatnumber('price', $currency, $lifetimelimit);

    # withdrawal since $numdays
    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
    my $withdrawal_for_x_days = $payment_mapper->get_total_withdrawal({
        start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
        exclude    => ['currency_conversion_transfer'],
    });
    $withdrawal_for_x_days = amount_from_to_currency($withdrawal_for_x_days, $currency, $withdrawal_limit_curr);

    # withdrawal since inception
    my $withdrawal_since_inception = amount_from_to_currency($payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']}),
        $currency, $withdrawal_limit_curr);

    my $remainder = min(($numdayslimit - $withdrawal_for_x_days), ($lifetimelimit - $withdrawal_since_inception));
    if ($remainder < 0) {
        $remainder = 0;
    }

    $limit->{withdrawal_since_inception_monetary} = formatnumber('price', $currency, $withdrawal_since_inception);
    $limit->{withdrawal_for_x_days_monetary}      = formatnumber('price', $currency, $withdrawal_for_x_days);
    $limit->{remainder}                           = formatnumber('price', $currency, $remainder);

    return $limit;
}

sub paymentagent_list {
    my $params = shift;

    my ($language, $args, $token_details) = @{$params}{qw/language args token_details/};

    my $client;
    if ($token_details and exists $token_details->{loginid}) {
        $client = Client::Account->new({loginid => $token_details->{loginid}});
    }

    my $broker_code = $client ? $client->broker_code : 'CR';

    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $countries = $payment_agent_mapper->get_all_authenticated_payment_agent_countries();

    # add country name plus code
    foreach (@{$countries}) {
        $_->[1] = Brands->new(name => request()->brand)->countries_instance->countries->localized_code2country($_->[0], $language);
    }

    my $authenticated_paymentagent_agents =
        $payment_agent_mapper->get_authenticated_payment_agents({target_country => $args->{paymentagent_list}});

    my ($payment_agent_table_row, $min_max) = ([], BOM::RPC::v3::Utility::paymentagent_default_min_max());
    foreach my $loginid (keys %{$authenticated_paymentagent_agents}) {
        my $payment_agent = $authenticated_paymentagent_agents->{$loginid};

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
            'max_withdrawal'        => $payment_agent->{max_withdrawal} // $min_max->{maximum},
            'min_withdrawal'        => $payment_agent->{min_withdrawal} // $min_max->{minimum},
            };
    }

    @$payment_agent_table_row = sort { lc($a->{name}) cmp lc($b->{name}) } @$payment_agent_table_row;

    return {
        available_countries => $countries,
        list                => $payment_agent_table_row
    };
}

sub paymentagent_transfer {
    my $params = shift;

    my $source    = $params->{source};
    my $client_fm = $params->{client};

    return BOM::RPC::v3::Utility::permission_error() if $client_fm->is_virtual;

    my $loginid_fm = $client_fm->loginid;

    my ($website_name, $args) = @{$params}{qw/website_name args/};
    my $currency   = $args->{currency};
    my $amount     = $args->{amount};
    my $loginid_to = uc $args->{transfer_to};

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'PaymentAgentTransferError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    return $error_sub->(localize('Invalid amount.')) if ($amount !~ /^\d*\.?\d*$/);

    my $error_msg;
    my $payment_agent = $client_fm->payment_agent;
    my $app_config    = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents
        or $app_config->system->suspend->system)
    {
        $error_msg = localize('Sorry, this facility is temporarily disabled due to system maintenance.');
    } elsif (not $client_fm->landing_company->allows_payment_agents) {
        $error_msg = localize('The payment agent facility is not available for this account.');
    } elsif (not $payment_agent) {
        $error_msg = localize('You are not authorized for transfers via payment agents.');
    } elsif (not $payment_agent->is_authenticated) {
        $error_msg = localize('Your account needs to be authenticated to perform payment agent transfers.');
    } elsif ($client_fm->cashier_setting_password) {
        $error_msg = localize('Your cashier is locked as per your request.');
    }

    return $error_sub->($error_msg) if $error_msg;

    my ($max_withdrawal, $min_withdrawal, $min_max) =
        ($payment_agent->max_withdrawal, $payment_agent->min_withdrawal, BOM::RPC::v3::Utility::paymentagent_default_min_max());
    if ($max_withdrawal) {
        return $error_sub->(localize("Invalid amount. Maximum withdrawal allowed is [_1].", $max_withdrawal)) if $amount > $max_withdrawal;
    } elsif ($amount > $min_max->{maximum}) {
        return $error_sub->(localize("Invalid amount. Maximum is [_1].", $min_max->{maximum}));
    }

    if ($min_withdrawal) {
        return $error_sub->(localize("Invalid amount. Minimum withdrawal allowed is [_1].", $min_withdrawal)) if $amount < $min_withdrawal;
    } elsif ($amount < $min_max->{minimum}) {
        return $error_sub->(localize('Invalid amount. Minimum is [_1].', $min_max->{minimum}));
    }

    return $error_sub->(localize('You cannot perform this action, as your account is currently disabled.')) if $client_fm->get_status('disabled');

    return $error_sub->(localize('You cannot perform this action, as your account is cashier locked.'))
        if $client_fm->get_status('cashier_locked');

    return $error_sub->(localize('This is an ICO-only account which does not support payment agent transfers.'))
        if $client_fm->get_status('ico_only');

    return $error_sub->(localize('You cannot perform this action, as your verification documents have expired.')) if $client_fm->documents_expired;

    my $client_to = try { Client::Account->new({loginid => $loginid_to}) };
    return $error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to)) unless $client_to;

    return $error_sub->(localize('Payment agent transfers are not allowed for the specified accounts.'))
        unless ($client_fm->landing_company->short eq $client_to->landing_company->short);

    return $error_sub->(localize('Payment agent transfers are not allowed within the same account.')) if $loginid_to eq $loginid_fm;

    return $error_sub->(localize('Payment agent transfers are available for [_1] currency only.', 'USD')) if $currency ne 'USD';

    return $error_sub->(
        localize('You cannot perform this action, as [_1] is not the default account currency for payment agent [_2].', $currency, $loginid_fm))
        if ($client_fm->currency ne $currency or not $client_fm->default_account);

    return $error_sub->(
        localize("You cannot perform this action, as [_1] is not the default account currency for client [_2].", $currency, $loginid_to))
        if ($client_to->currency ne $currency or not $client_to->default_account);

    return $error_sub->(localize('You cannot transfer to account [_1], as their account is currently disabled.', $loginid_to))
        if $client_to->get_status('disabled');

    return $error_sub->(localize('You cannot transfer to account [_1], as their account is marked as unwelcome.', $loginid_to))
        if $client_to->get_status('unwelcome');

    return $error_sub->(localize('You cannot transfer to account [_1], as their cashier is locked.', $loginid_to))
        if ($client_to->get_status('cashier_locked') or $client_to->cashier_setting_password);
    return $error_sub->(localize('This is an ICO-only account which does not support transfers.'))
        if $client_to->get_status('ico_only');

    return $error_sub->(localize('You cannot transfer to account [_1], as their verification documents have expired.', $loginid_to))
        if $client_to->documents_expired;

    if ($args->{dry_run}) {
        return {
            status              => 2,
            client_to_full_name => $client_to->full_name,
            client_to_loginid   => $client_to->loginid
        };
    }

    # freeze loginID to avoid a race condition
    my $fm_client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid_fm,
    });
    my $to_client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid_to,
    });

    my $guard_scope = guard {
        $fm_client_db->unfreeze;
        $to_client_db->unfreeze;
    };

    if (not $fm_client_db->freeze) {
        return $error_sub->(
            localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
            "Account stuck in previous transaction $loginid_fm"
        );
    }

    if (not $to_client_db->freeze) {
        return $error_sub->(
            localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
            "Account stuck in previous transaction $loginid_to"
        );
    }

    my $withdraw_error;
    try {
        $client_fm->validate_payment(
            currency => $currency,
            amount   => -$amount,    # withdraw action use negative amount
        );
    }
    catch {
        $withdraw_error = $_;
    };

    if ($withdraw_error) {
        return $error_sub->(
            __client_withdrawal_notes({
                    client => $client_fm,
                    amount => $amount,
                    error  => $withdraw_error
                }));
    }

    # check that there's no identical transaction
    my ($amount_transferred, $count) = _get_amount_and_count($loginid_fm);

    # maximum amount USD 100000 per day
    if (($amount_transferred + $amount) >= 100000) {
        return $error_sub->(
            localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transfer amount for today.'));
    }

    # do not allow more than 1000 transactions per day
    if ($count > 1000) {
        return $error_sub->(localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.'));
    }

    if ($client_to->default_account and $amount + $client_to->default_account->balance > $client_to->get_limit_for_account_balance) {
        return $error_sub->(
            localize(
                'Payment agent transfer is not allowed with the specified amount, as account [_1] balance would exceed allowed limits.', $loginid_to
            ));
    }

    # execute the transfer
    my $now       = Date::Utility->new;
    my $today     = $now->datetime_ddmmmyy_hhmmss_TZ;
    my $reference = Data::UUID->new()->create_str();
    my $comment =
        'Transfer from Payment Agent ' . $payment_agent->payment_agent_name . " to $loginid_to. Transaction reference: $reference. Timestamp: $today";

    my ($error, $response);
    try {
        $response = $client_fm->payment_account_transfer(
            toClient => $client_to,
            currency => $currency,
            amount   => $amount,
            fmStaff  => $loginid_fm,
            toStaff  => $loginid_to,
            remark   => $comment,
            source   => $source,
            fees     => 0,
        );
    }
    catch {
        chomp;
        $error = "Paymentagent Transfer failed to $loginid_to [$_]";
    };

    if ($error) {
        # too many attempts
        if ($error =~ /BI102/) {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $error);
        } else {
            warn "Error in paymentagent_transfer for transfer - $error\n";
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request.'), $error);
        }
    }

    BOM::Platform::PaymentNotificationQueue->add(
        source        => 'payment_agent',
        currency      => $currency,
        loginid       => $loginid_to,
        type          => 'deposit',
        amount        => $amount,
        payment_agent => 0,
    );

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
}

sub paymentagent_withdraw {
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
    my $further_instruction  = $args->{description} // '';
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

    # check that the amount is in correct format
    return $error_sub->(localize('Invalid amount.')) if ($amount !~ /^\d*\.?\d*$/);

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents
        or $app_config->system->suspend->system)
    {
        return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'));
    } elsif (not $client->landing_company->allows_payment_agents) {
        return $error_sub->(localize('Payment agent facilities are not available for this account.'));
    } elsif (not BOM::Transaction::Validation->new({clients => [$client]})->allow_paymentagent_withdrawal($client)) {
        # check whether allow to withdraw via payment agent
        return $error_sub->(localize('You are not authorized for withdrawals via payment agents.'));
    } elsif ($client->cashier_setting_password) {
        return $error_sub->(localize('Your cashier is locked as per your request.'));
    }

    my $authenticated_pa;
    if ($client->residence) {
        my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $client->broker});
        $authenticated_pa = $payment_agent_mapper->get_authenticated_payment_agents({target_country => $client->residence});
    }

    return $error_sub->(localize('The payment agent facility is currently not available in your country.'))
        if (not $client->residence or scalar keys %{$authenticated_pa} == 0);

    return $error_sub->(localize('You cannot perform this action, as your account is currently disabled.')) if $client->get_status('disabled');

    my $min_max = BOM::RPC::v3::Utility::paymentagent_default_min_max();
    return $error_sub->(localize('Invalid amount. Minimum is [_1], maximum is [_2].', $min_max->{minimum}, $min_max->{maximum}))
        if ($amount < $min_max->{minimum} || $amount > $min_max->{maximum});

    my $paymentagent = Client::Account::PaymentAgent->new({'loginid' => $paymentagent_loginid})
        or return $error_sub->(localize('The payment agent account does not exist.'));

    return $error_sub->(localize('Payment agent transfers are not allowed for specified accounts.')) if ($client->broker ne $paymentagent->broker);

    my $pa_client = $paymentagent->client;
    return $error_sub->(
        localize('You cannot perform this action, as [_1] is not default currency for your account [_2].', $currency, $client->loginid))
        if ($client->currency ne $currency or not $client->default_account);

    return $error_sub->(localize("You cannot perform this action, as [_1] is not default currency for payment agent account [_2].", $currency))
        if ($pa_client->currency ne $currency or not $pa_client->default_account);

    # check that the additional information does not exceeded the allowed limits
    return $error_sub->(localize('Further instructions must not exceed [_1] characters.', 300)) if (length($further_instruction) > 300);

    return $error_sub->(localize('This is an ICO-only account which does not support transfers.'))
        if $client->get_status('ico_only');

    # check that both the client payment agent cashier is not locked
    return $error_sub->(localize('You cannot perform this action, as your account is cashier locked.')) if $client->get_status('cashier_locked');

    return $error_sub->(localize('You cannot perform this action, as your account is withdrawal locked.'))
        if $client->get_status('withdrawal_locked');

    return $error_sub->(localize('You cannot perform this action, as your verification documents have expired.')) if $client->documents_expired;

    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is disabled.", $pa_client->loginid))
        if $pa_client->get_status('disabled');

    return $error_sub->(
        localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is marked as unwelcome.", $pa_client->loginid))
        if $pa_client->get_status('unwelcome');

    return $error_sub->(localize("You cannot perform the withdrawal to account [_1], as the payment agent's cashier is locked.", $pa_client->loginid))
        if ($pa_client->get_status('cashier_locked') or $pa_client->cashier_setting_password);

    return $error_sub->(localize('This is an ICO-only account which does not support transfers.'))
        if $pa_client->get_status('ico_only');

    return $error_sub->(localize("You cannot perform withdrawal to account [_1], as payment agent's verification documents have expired."))
        if $pa_client->documents_expired;

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
    if (not $client_db->freeze) {
        return $error_sub->(
            localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
            "Account stuck in previous transaction $client_loginid"
        );
    }
    if (not $paymentagent_client_db->freeze) {
        return $error_sub->(
            localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'),
            "Account stuck in previous transaction $paymentagent_loginid"
        );
    }

    my $withdraw_error;
    try {
        $client->validate_payment(
            currency => $currency,
            amount   => -$amount,    #withdraw action use negtive amount
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

    # check that there's no identical transaction
    my ($amount_transferred, $count) = _get_amount_and_count($client_loginid);

    # max withdrawal daily limit: weekday = $5000, weekend = $1500
    my $daily_limit = (DateTime->now->day_of_week() > 5) ? 1500 : 5000;

    if (($amount_transferred + $amount) > $daily_limit) {
        return $error_sub->(localize('Sorry, you have exceeded the maximum allowable transfer amount [_1] for today.', $currency . $daily_limit));
    }

    # do not allowed more than 20 transactions per day
    if ($count > 20) {
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
            currency => $currency,
            amount   => $amount,
            remark   => $comment,
            fmStaff  => $client_loginid,
            toStaff  => $paymentagent_loginid,
            toClient => $pa_client,
            source   => $source,
            fees     => 0,
        );
    }
    catch {
        $error = "Paymentagent Withdraw failed to $paymentagent_loginid [$_]";
    };

    if ($error) {
        # too many attempts
        if ($error =~ /BI102/) {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $error);
        } else {
            warn "Error in paymentagent_transfer for withdrawal - $error\n";
            return $error_sub->(localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.'), $error);
        }
    }

    BOM::Platform::PaymentNotificationQueue->add(
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
}

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

sub transfer_between_accounts {
    my $params = shift;

    my ($client, $source) = @{$params}{qw/client source/};

    if (BOM::Platform::Client::CashierValidation::is_system_suspended() or BOM::Platform::Client::CashierValidation::is_payment_suspended()) {
        return _transfer_between_accounts_error(localize('Payments are suspended.'));
    }

    {    # Reject all transfers when forex markets are closed
        my $can_transfer = 0;
        # Although this is hardcoded as BTC, the intention is that any risky transfer should be blocked at weekends.
        # Currently, this implies crypto to fiat or vice versa, and BTC is our most volatile (and popular) crypto
        # currency. If the exchange is updated to something other than forex, this check should start allowing
        # transfers at weekends again - note that we expect https://trello.com/c/bvhH85GJ/5700-13-tom-centralredisexchangerates
        # to block exchange when the quotes are too old.
        if (my $ul = create_underlying('frxBTCUSD')) {
            # This is protected by an `eval` call since the author is currently in Cambodia and likely to
            # be making mistakes at this time on a Friday. Technically we should not need it - if we can't
            # instantiate the trading calendar, we have bigger problems than a stray exception during rare
            # RPC calls such as account transfer.
            $can_transfer = 1
                if eval {
                Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader)
                    ->is_open_at($ul->exchange, Date::Utility->new);
                };
        }
        return _transfer_between_accounts_error(localize('Account transfers are currently suspended.')) unless $can_transfer;
    }

    return BOM::RPC::v3::Utility::permission_error() if $client->is_virtual;

    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is currently disabled.'))
        if $client->get_status('disabled');
    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is cashier locked.'))
        if $client->get_status('cashier_locked');

    return _transfer_between_accounts_error(localize('You cannot perform this action, as your account is withdrawal locked.'))
        if $client->get_status('withdrawal_locked');
    return _transfer_between_accounts_error(localize('Your cashier is locked as per your request.')) if $client->cashier_setting_password;

    my $args = $params->{args};
    my ($currency, $amount) = @{$args}{qw/currency amount/};

    my $siblings = BOM::RPC::v3::Utility::get_real_account_siblings_information($client->loginid, 1);
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
        $client_from = Client::Account->new({loginid => $siblings->{$loginid_from}->{loginid}});
        $client_to   = Client::Account->new({loginid => $siblings->{$loginid_to}->{loginid}});
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

    my ($to_amount, $fees, $fees_percent) =
        BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($client_from->loginid, $amount, $from_currency, $to_currency);

    BOM::Platform::AuditLog::log("Account Transfer ATTEMPT, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    my $error_audit_sub = sub {
        my ($err, $client_message) = @_;

        BOM::Platform::AuditLog::log("Account Transfer FAILED, $err");

        $client_message ||= localize('Sorry, an error occurred whilst processing your request. Please try again in one minute.');
        return _transfer_between_accounts_error($client_message);
    };

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

    my $err;
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
        $err = "$err_msg validate_payment failed for $loginid_to [$_]";
    };
    if ($err) {
        return $error_audit_sub->($err);
    }

    my $response;
    try {
        my $remark = 'Account transfer from ' . $loginid_from . ' to ' . $loginid_to . '.';
        if ($fees) {
            $remark .= " Includes $currency " . formatnumber('amount', $currency, $fees) . " ($fees_percent%) as fees.";
        }
        $response = $client_from->payment_account_transfer(
            currency          => $currency,
            amount            => $amount,
            toClient          => $client_to,
            fmStaff           => $loginid_from,
            toStaff           => $loginid_to,
            remark            => $remark,
            inter_db_transfer => ($client_from->landing_company->short ne $client_to->landing_company->short),
            source            => $source,
            fees              => $fees,
        );
    }
    catch {
        $err = "$err_msg Account Transfer failed [$_]";
    };
    if ($err) {
        return $error_audit_sub->($err);
    }

    BOM::Platform::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    return {
        status              => 1,
        transaction_id      => $response->{transaction_id},
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $loginid_to
    };
}

sub topup_virtual {
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

    my $currency = $client->default_account->currency_code;
    my $minimum_topup_balance = $currency eq 'JPY' ? 100000 : 1000;
    if ($client->default_account->balance > $minimum_topup_balance) {
        return $error_sub->(localize('Your balance is higher than the permitted amount.'));
    }

    if (scalar($client->open_bets)) {
        return $error_sub->(localize('Sorry, you have open positions. Please close out all open positions before requesting additional funds.'));
    }

    # CREDIT HIM WITH THE MONEY
    my ($curr, $amount) = $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

    return {
        amount   => $amount,
        currency => $curr
    };
}

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
        if $client_to->get_status('disabled');

    return _transfer_between_accounts_error(
        localize('You cannot perform this action, as your account [_1] is marked as unwelcome.', $client_to->loginid))
        if $client_to->get_status('unwelcome');

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

    my $min_allowed_amount = BOM::Platform::Runtime->instance->app_config->payments->transfer_between_accounts->amount->$from_currency_type->min;
    return _transfer_between_accounts_error(
        localize(
            'Provided amount is not within permissible limits. Minimum transfer amount for provided currency is [_1].',
            formatnumber('amount', $currency, $min_allowed_amount))) if $amount < $min_allowed_amount;

    return _transfer_between_accounts_error(
        localize(
            'Invalid amount. Amount provided can not have more than [_1] decimal places',
            Format::Util::Numbers::get_precision_config()->{amount}->{$currency})) if ($amount != financialrounding('amount', $currency, $amount));

    my $to_currency_type = LandingCompany::Registry::get_currency_type($to_currency);

    # we don't allow fiat to fiat if they are different
    return _transfer_between_accounts_error(localize('Account transfers are not available for accounts with different currencies.'))
        if (($from_currency_type eq $to_currency_type) and ($from_currency_type eq 'fiat') and ($currency ne $to_currency));

    # we don't allow crypto to crypto transfer
    return _transfer_between_accounts_error(localize('Account transfers are not available within accounts with cryptocurrency as default currency.'))
        if (($from_currency_type eq $to_currency_type) and ($from_currency_type eq 'crypto'));

    return undef;
}

1;

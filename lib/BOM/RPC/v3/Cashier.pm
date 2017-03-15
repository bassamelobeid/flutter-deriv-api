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
use Format::Util::Numbers qw(roundnear);
use String::UTF8::MD5;
use LWP::UserAgent;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use YAML::XS qw(LoadFile);

use Brands;
use Client::Account;
use LandingCompany::Registry;
use Client::Account::PaymentAgent;

use Postgres::FeedDB::CurrencyConverter qw(amount_from_to_currency);

use BOM::Platform::User;
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook get_doughflow_language_code_for );
use BOM::Platform::Runtime;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Config;
use BOM::Platform::AuditLog;
use BOM::Platform::RiskProfile;
use BOM::RPC::v3::Utility;

use BOM::Database::Model::HandoffToken;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::ClientDB;

my $payment_limits = LoadFile(File::ShareDir::dist_file('Client-Account', 'payment_limits.yml'));

sub cashier {
    my $params = shift;

    my $client = $params->{client};

    if ($client->is_virtual) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CashierForwardError',
            message_to_client => localize('This is a virtual-money account. Please switch to a real-money account to deposit funds.'),
        });
    }

    my $args     = $params->{args};
    my $action   = $args->{cashier} // 'deposit';
    my $provider = $args->{provider} // 'doughflow';

    my $currency;
    if (my $account = $client->default_account) {
        $currency = $account->currency_code;
    }

    # still no currency?  Try the first financial sibling with same landing co.
    unless ($currency) {
        my $user = BOM::Platform::User->new({email => $client->email});
        unless ($user) {
            warn __PACKAGE__ . "::cashier Error:  Unable to get user data for " . $client->loginid . "\n";
            return BOM::RPC::v3::Utility::create_error({
                code              => 'CashierForwardError',
                message_to_client => localize('Internal server error'),
            });
        }
        for (grep { $_->landing_company->short eq $client->landing_company->short } $user->clients) {
            if (my $default_account = $_->default_account) {
                $currency = $default_account->currency_code;
                last;
            }
        }
    }

    my $landing_company = $client->landing_company;
    if ($landing_company->short eq 'maltainvest') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ASK_AUTHENTICATE',
                message_to_client => localize('Client is not fully authenticated.')}) unless $client->client_fully_authenticated;

        return BOM::RPC::v3::Utility::create_error({
                code              => 'ASK_FINANCIAL_RISK_APPROVAL',
                message_to_client => localize('Financial Risk approval is required.')}) unless $client->get_status('financial_risk_approval');

        return BOM::RPC::v3::Utility::create_error({
                code              => 'ASK_TIN_INFORMATION',
                message_to_client => localize(
                    'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.')}
        ) unless $client->get_status('crs_tin_information');
    }

    if ($client->residence eq 'gb' and not $client->get_status('ukgc_funds_protection')) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ASK_UK_FUNDS_PROTECTION',
            message_to_client => localize('Please accept Funds Protection.'),
        });
    }

    if ($client->residence eq 'jp' and ($client->get_status('jp_knowledge_test_pending') or $client->get_status('jp_knowledge_test_fail'))) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ASK_JP_KNOWLEDGE_TEST',
            message_to_client => localize('You must complete the knowledge test to activate this account.'),
        });
    }

    if ($client->residence eq 'jp' and $client->get_status('jp_activation_pending')) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'JP_NOT_ACTIVATION',
            message_to_client => localize('Account not activated.'),
        });
    }

    if (   $client->landing_company->country eq 'Japan'
        && !$client->get_status('age_verification')
        && !$client->has_valid_documents)
    {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ASK_AGE_VERIFICATION',
            message_to_client => localize('Account needs age verification'),
        });
    }

    my $error = '';
    my $brand = Brands->new(name => request()->brand);
    if ($action eq 'deposit' and $client->get_status('unwelcome')) {
        $error = localize('Your account is restricted to withdrawals only.');
    } elsif ($client->documents_expired) {
        $error = localize(
            'Your identity documents have passed their expiration date. Kindly send a scan of a valid ID to <a href="mailto:[_1]">[_1]</a> to unlock your cashier.',
            $brand->emails('support'));
    } elsif ($client->get_status('cashier_locked')) {
        $error = localize('Your cashier is locked');
    } elsif ($client->get_status('disabled')) {
        $error = localize('Your account is disabled');
    } elsif ($client->cashier_setting_password) {
        $error = localize('Your cashier is locked as per your request.');
    } elsif ($action eq 'withdraw' and $client->get_status('withdrawal_locked')) {
        $error = localize('Your account is locked for withdrawals. Please contact customer service.');
    } elsif ($currency and not $landing_company->is_currency_legal($currency)) {
        $error = localize('[_1] transactions may not be performed with this account.', $currency);
    }

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'CashierForwardError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    if ($error) {
        return $error_sub->($error);
    }

    my $df_client;
    my $client_loginid = $client->loginid;
    if ($provider eq 'doughflow') {
        $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $client_loginid});
        # We ask the client which currency they wish to deposit/withdraw in
        # if they've never deposited before
        $currency = $currency || $df_client->doughflow_currency;
    }

    if (not $currency) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'ASK_CURRENCY',
            message_to_client => 'Please set the currency.',
        });
    }

    my $email = $client->email;
    if ($action eq 'withdraw') {
        my $is_not_verified = 1;
        my $token = $args->{verification_code} // '';

        if (not $email or $email =~ /\s+/) {
            $error_sub->(localize("Client email not set."));
        } elsif ($token) {
            if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($token, $client->email, 'payment_withdraw')->{error}) {
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

    ## if cashier provider == 'epg', we'll return epg url
    if ($provider eq 'epg') {
        return _get_epg_url($client->loginid, $params->{website_name}, $currency, $action, $params->{language});
    }

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
                    'Sorry, there was a problem validating your personal information with our payment processor. Please contact our Customer Service.'
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
                    'Sorry, there was a problem validating your personal information with our payment processor. Please contact our Customer Service team.'
                ),
                'Error with DF CreateCustomer API loginid[' . $df_client->loginid . '] error[' . $errortext . ']'
            );
        }

        warn "Unknown Doughflow error: $errortext\n";

        return $error_sub->(
            localize('Sorry, an error has occurred, Please try accessing our Cashier again.'),
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

sub _get_epg_url {
    my ($loginid, $website_name, $currency, $action, $language) = @_;

    BOM::Platform::AuditLog::log('redirecting to epg');

    $language = uc($language // 'EN');

    my $url = 'https://';
    if (($website_name // '') =~ /qa/) {
        $url .= 'www.' . lc($website_name) . '/epg';
    } else {
        $url .= 'epg.binary.com/epg';
    }

    $url .= "/handshake?token=" . _get_handoff_token_key($loginid) . "&loginid=$loginid&currency=$currency&action=$action&l=$language";

    return $url;
}

sub get_limits {
    my $params = shift;

    my $client         = $params->{client};
    my $client_loginid = $client->loginid;

    if ($client->get_status('cashier_locked') or $client->documents_expired or $client->is_virtual) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'FeatureNotAvailable',
                message_to_client => localize('Sorry, this feature is not available.')});
    }

    my $landing_company = LandingCompany::Registry::get_by_broker($client->broker)->short;
    my $wl_config       = $payment_limits->{withdrawal_limits}->{$landing_company};

    my $limit = +{
        account_balance => $client->get_limit_for_account_balance,
        payout          => $client->get_limit_for_payout,
        payout_per_symbol_and_contract_type =>
            BOM::Platform::Config::quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit}->{$client->currency},
        open_positions => $client->get_limit_for_open_positions,
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
        $withdrawal_limit_curr = $client->currency;
    } else {
        # limit in EUR for: MX, MLT, MF
        $withdrawal_limit_curr = 'EUR';
    }

    $limit->{num_of_days}       = $numdays;
    $limit->{num_of_days_limit} = $numdayslimit;
    $limit->{lifetime_limit}    = $lifetimelimit;

    if (not $client->client_fully_authenticated) {
        # withdrawal since $numdays
        my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
        my $withdrawal_for_x_days = $payment_mapper->get_total_withdrawal({
            start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
            exclude    => ['currency_conversion_transfer'],
        });
        $withdrawal_for_x_days = roundnear(0.01, amount_from_to_currency($withdrawal_for_x_days, $client->currency, $withdrawal_limit_curr));

        # withdrawal since inception
        my $withdrawal_since_inception = $payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']});
        $withdrawal_since_inception =
            roundnear(0.01, amount_from_to_currency($withdrawal_since_inception, $client->currency, $withdrawal_limit_curr));

        $limit->{withdrawal_since_inception_monetary} = $withdrawal_since_inception;
        $limit->{withdrawal_for_x_days_monetary}      = $withdrawal_for_x_days;

        my $remainder = roundnear(0.01, min(($numdayslimit - $withdrawal_for_x_days), ($lifetimelimit - $withdrawal_since_inception)));
        if ($remainder < 0) {
            $remainder = 0;
        }

        $limit->{remainder} = $remainder;
    }

    return $limit;
}

sub paymentagent_list {
    my $params = shift;
    my ($language, $args) = @{$params}{qw/language args/};

    my $token_details = $params->{token_details};
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

    my $payment_agent_table_row = [];
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
    my $reject_error_sub = sub {
        my $msg = shift;
        return $error_sub->(
            __output_payments_error_message({
                    client       => $client_fm,
                    action       => "transfer - from $loginid_fm to $loginid_to",
                    error_msg    => $msg,
                    payment_type => 'Payment Agent transfer',
                    currency     => $currency,
                    amount       => $amount,
                }));
    };

    my $error_msg;
    my $payment_agent = $client_fm->payment_agent;
    my $app_config    = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents
        or $app_config->system->suspend->system)
    {
        $error_msg = localize('Sorry, Payment Agent Transfer is temporarily disabled due to system maintenance. Please try again in 30 minutes.');
    } elsif (not $client_fm->landing_company->allows_payment_agents) {
        $error_msg = localize('Payment Agents are not available on this site.');
    } elsif (not $payment_agent) {
        $error_msg = localize('You are not a Payment Agent');
    } elsif (not $payment_agent->is_authenticated) {
        $error_msg = localize('Payment Agent activity not currently authorized');
    } elsif ($client_fm->cashier_setting_password) {
        $error_msg = localize('Your cashier is locked as per your request');
    }

    if ($error_msg) {
        return $error_sub->($error_msg);
    }

    ## validate amount
    if ($amount < 10 || $amount > 2000) {
        return $error_sub->(localize('Invalid amount. minimum is 10, maximum is 2000.'));
    }

    my $client_to = try { Client::Account->new({loginid => $loginid_to}) };
    unless ($client_to) {
        return $reject_error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to));
    }

    unless ($client_fm->landing_company->short eq $client_to->landing_company->short) {
        return $reject_error_sub->(localize('Cross-company payment agent transfers are not allowed.'));
    }

    if ($loginid_to eq $loginid_fm) {
        return $reject_error_sub->(localize('Sorry, it is not allowed.'));
    }

    if ($currency ne 'USD') {
        return $reject_error_sub->(localize('Sorry, only USD is allowed.'));
    }

    unless ($client_fm->currency eq $currency) {
        return $reject_error_sub->(localize("Sorry, [_1] is not default currency for payment agent [_2]", $currency, $client_fm->loginid));
    }
    unless ($client_to->currency eq $currency) {
        return $reject_error_sub->(localize("Sorry, [_1] is not default currency for client [_2]", $currency, $client_to->loginid));
    }

    if ($client_to->get_status('disabled')) {
        return $reject_error_sub->(localize('You cannot transfer to account [_1], as their account is currently disabled.', $loginid_to));
    }

    if ($client_to->get_status('cashier_locked') || $client_to->documents_expired) {
        return $reject_error_sub->(localize('There was an error processing the request.') . ' ' . localize('This client cashier section is locked.'));
    }

    if ($client_fm->get_status('cashier_locked') || $client_fm->documents_expired) {
        return $reject_error_sub->(localize('There was an error processing the request.') . ' ' . localize('Your cashier section is locked.'));
    }

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
    if (not $fm_client_db->freeze) {
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
            "Account stuck in previous transaction $loginid_fm"
        );
    }

    my $to_client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid_to,
    });

    if (not $to_client_db->freeze) {
        $fm_client_db->unfreeze;
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
            "Account stuck in previous transaction $loginid_to"
        );
    }

    my $withdraw_error;
    try {
        $client_fm->validate_payment(
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
                    client => $client_fm,
                    amount => $amount,
                    error  => $withdraw_error
                }));
    }

    # check that there's no identical transaction
    my ($amount_transferred, $count) = _get_amount_and_count($loginid_fm);

    # maximum amount USD 100000 per day
    if (($amount_transferred + $amount) >= 100000) {
        $fm_client_db->unfreeze;
        $to_client_db->unfreeze;

        return $reject_error_sub->(localize('Sorry, you have exceeded the maximum allowable transfer amount for today.'));
    }

    # do not allow more than 1000 transactions per day
    if ($count > 1000) {
        $fm_client_db->unfreeze;
        $to_client_db->unfreeze;

        return $reject_error_sub->(localize('Sorry, you have exceeded the maximum allowable transactions for today.'));
    }

    if ($client_to->default_account and $amount + $client_to->default_account->balance > $client_to->get_limit_for_account_balance) {
        $fm_client_db->unfreeze;
        $to_client_db->unfreeze;
        return $reject_error_sub->(localize('Sorry, client balance will exceed limits with this payment.'));
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
        );
    }
    catch {
        $error = "Paymentagent Transfer failed to $loginid_to [$_]";
    };

    $fm_client_db->unfreeze;
    $to_client_db->unfreeze;

    if ($error) {
        # too many attempts
        if ($error =~ /BI102/) {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $error);
        } else {
            return $error_sub->(localize('An error occurred while processing request. If this error persists, please contact customer support'),
                $error);
        }
    }

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
        my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $client->email, 'paymentagent_withdraw')->{error};
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
    my $reject_error_sub = sub {
        my $msg = shift;
        return $error_sub->(
            __output_payments_error_message({
                    client       => $client,
                    action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
                    error_msg    => $msg,
                    payment_type => 'Payment Agent Withdrawal',
                    currency     => $currency,
                    amount       => $amount,
                }));
    };

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents
        or $app_config->system->suspend->system)
    {
        return $error_sub->(
            localize('Sorry, the Payment Agent Withdrawal is temporarily disabled due to system maintenance. Please try again in 30 minutes.'));
    } elsif (not $client->landing_company->allows_payment_agents) {
        return $error_sub->(localize('Payment Agents are not available on this site.'));
    } elsif (not $client->allow_paymentagent_withdrawal()) {
        # check whether allow to withdraw via payment agent
        return $reject_error_sub->(localize('You are not authorized for withdrawal via payment agent.'));
    } elsif ($client->cashier_setting_password) {
        return $error_sub->(localize('Your cashier is locked as per your request.'));
    }

    my $authenticated_pa;
    if ($client->residence) {
        my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $client->broker});
        $authenticated_pa = $payment_agent_mapper->get_authenticated_payment_agents({target_country => $client->residence});
    }

    if (not $client->residence or scalar keys %{$authenticated_pa} == 0) {
        return $error_sub->(localize('The Payment Agent facility is currently not available in your country.'));
    }

    ## validate amount
    if ($amount < 10 || $amount > 2000) {
        return $error_sub->(localize('Invalid amount. minimum is 10, maximum is 2000.'));
    }

    my $paymentagent = Client::Account::PaymentAgent->new({'loginid' => $paymentagent_loginid})
        or return $error_sub->(localize('Sorry, the Payment Agent does not exist.'));

    if ($client->broker ne $paymentagent->broker) {
        return $error_sub->(localize('Sorry, the Payment Agent is unavailable for your region.'));
    }

    my $pa_client = $paymentagent->client;

    # check that the currency is in correct format
    if ($client->currency ne $currency) {
        return $error_sub->(localize('Sorry, your currency of [_1] is unavailable for Payment Agent Withdrawal', $currency));
    }

    if ($pa_client->currency ne $currency) {
        return $error_sub->(localize("Sorry, the Payment Agent's currency [_1] is unavailable for Payment Agent Withdrawal", $currency));
    }

    # check that the amount is in correct format
    if ($amount !~ /^\d*\.?\d*$/) {
        return $reject_error_sub->(localize('There was an error processing the request.'));
    }

    # check that the additional information does not exceeded the allowed limits
    if (length($further_instruction) > 300) {
        return $reject_error_sub->(localize('Further instructions must not exceed [_1] characters.', 300));
    }

    # check that both the client payment agent cashier is not locked
    if ($client->get_status('cashier_locked') || $client->get_status('withdrawal_locked') || $client->documents_expired) {
        return $reject_error_sub->(localize('There was an error processing the request.'));
    }
    if ($pa_client->get_status('cashier_locked') || $client->documents_expired) {
        return $reject_error_sub->(localize('This Payment Agent cashier section is locked.'));
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

    # freeze loginID to avoid a race condition
    if (not $client_db->freeze) {
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
            "Account stuck in previous transaction $client_loginid"
        );
    }
    my $paymentagent_client_db = BOM::Database::ClientDB->new({
        client_loginid => $paymentagent_loginid,
    });

    if (not $paymentagent_client_db->freeze) {
        $client_db->unfreeze;
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
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
        $client_db->unfreeze;
        $paymentagent_client_db->unfreeze;

        return $reject_error_sub->(
            localize('Sorry, you have exceeded the maximum allowable transfer amount [_1] for today.', $currency . $daily_limit));
    }

    if ($amount_transferred > 1500) {
        my $message = "Client $client_loginid transferred \$$amount_transferred to payment agent today";
        my $brand = Brands->new(name => request()->brand);
        send_email({
            from    => $brand->emails('support'),
            to      => $brand->emails('support'),
            subject => $message,
            message => [$message],
        });
    }

    # do not allowed more than 20 transactions per day
    if ($count > 20) {
        $client_db->unfreeze;
        $paymentagent_client_db->unfreeze;

        return $reject_error_sub->(localize('Sorry, you have exceeded the maximum allowable transactions for today.'));
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
        );
    }
    catch {
        $error = "Paymentagent Withdraw failed to $paymentagent_loginid [$_]";
    };

    $client_db->unfreeze;
    $paymentagent_client_db->unfreeze;

    if ($error) {
        # too many attempts
        if ($error =~ /BI102/) {
            return $error_sub->(localize('Request too frequent. Please try again later.'), $error);
        } else {
            return $error_sub->(localize('An error occurred while processing request. If this error persists, please contact customer support'),
                $error);
        }
    }

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

sub __output_payments_error_message {
    my $args          = shift;
    my $client        = $args->{'client'};
    my $action        = $args->{'action'};
    my $payment_type  = $args->{'payment_type'} || 'n/a';    # used for reporting; if not given, not applicable
    my $currency      = $args->{'currency'};
    my $amount        = $args->{'amount'};
    my $error_message = $args->{'error_msg'};

    my $brand          = Brands->new(name => request()->brand);
    my $payments_email = $brand->emails('payments');
    my $cs_email       = $brand->emails('support');

    # amount is not always exist because error may happen before client submit the form
    # or when redirected from 3rd party site to failure script where no data is returned
    my $email_amount = $amount ? "Amount : $currency $amount" : '';
    my $now          = Date::Utility->new;
    my $message      = [
        "Details of the payment error :\n",
        "Date/Time : " . $now->datetime,
        "Action : " . ucfirst $action . " via $payment_type",
        "Login ID : " . $client->loginid,
        $email_amount,
        "Error message : $error_message",
    ];

    send_email({
        from    => $cs_email,
        to      => $payments_email,
        subject => 'Payment Error: ' . $payment_type . ' [' . $client->loginid . ']',
        message => $message,
    });

    # write error to deposit-failure.log
    if ($action eq 'deposit') {
        Path::Tiny::path('/var/log/fixedodds/deposit-error.log')
            ->append($now->datetime . ' LoginID:' . $client->loginid . " Method: $payment_type Amount: $currency $amount Error: $error_message");
    }

    return $error_message;
}

sub __client_withdrawal_notes {
    my $arg_ref  = shift;
    my $client   = $arg_ref->{'client'};
    my $amount   = roundnear(0.01, $arg_ref->{'amount'});
    my $error    = $arg_ref->{'error'};
    my $currency = $client->currency;
    my $balance  = $client->default_account ? roundnear(0.01, $client->default_account->balance) : 0;

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

## This endpoint is only available for MLT/MF accounts
sub transfer_between_accounts {
    my $params = shift;

    my $client = $params->{client};
    my $source = $params->{source};
    my $user;

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'TransferBetweenAccountsError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->system)
    {
        return $error_sub->(localize('Payments are suspended.'));
    }
    unless ($user = BOM::Platform::User->new({email => $client->email})) {
        warn __PACKAGE__ . "::transfer_between_accounts Error:  Unable to get user data for " . $client->loginid . "\n";
        return $error_sub->(localize('Internal server error'));
    }
    if ($client->get_status('disabled') or $client->get_status('cashier_locked') or $client->get_status('withdrawal_locked')) {
        return $error_sub->(localize('The account transfer is unavailable for your account: [_1].', $client->loginid));
    }

    my $args         = $params->{args};
    my $loginid_from = $args->{account_from};
    my $loginid_to   = $args->{account_to};
    my $currency     = $args->{currency};
    my $amount       = $args->{amount};

    my %siblings = map { $_->loginid => $_ } $user->clients;

    my @accounts;
    foreach my $account (values %siblings) {
        # check if client has any sub_account_of as we allow omnibus transfers also
        # for MLT MF transfer check landing company
        my $sub_account = $account->sub_account_of // '';
        if ($client->loginid eq $sub_account || (grep { $account->landing_company->short eq $_ } ('malta', 'maltainvest'))) {
            push @accounts,
                {
                loginid => $account->loginid,
                balance => $account->default_account ? sprintf('%.2f', $account->default_account->balance) : "0.00",
                currency => $account->default_account ? $account->default_account->currency_code : '',
                };
        } else {
            next;
        }

    }

    # get clients
    unless ($loginid_from and $loginid_to and $currency and $amount) {
        return {
            status   => 0,
            accounts => \@accounts
        };
    }

    if (not looks_like_number($amount) or $amount < 0.1 or $amount !~ /^\d+.?\d{0,2}$/) {
        return $error_sub->(localize('Invalid amount. Minimum transfer amount is 0.10, and up to 2 decimal places.'));
    }

    my ($is_good, $client_from, $client_to) = (0, $siblings{$loginid_from}, $siblings{$loginid_to});

    if ($client_from && $client_to) {
        # for sub account we need to check if it fulfils sub_account_of criteria and allow_omnibus is set
        if (
            ($client_from->allow_omnibus || $client_to->allow_omnibus)
            && (   ($client_from->sub_account_of && $client_from->sub_account_of eq $loginid_to)
                || ($client_to->sub_account_of && $client_to->sub_account_of eq $loginid_from)))
        {
            $is_good = 1;
        } else {
            my %landing_companies = (
                $client_from->landing_company->short => 1,
                $client_to->landing_company->short   => 1,
            );

            # check for transfer between malta & maltainvest
            $is_good = $landing_companies{malta} && $landing_companies{maltainvest};
        }
    }

    unless ($is_good) {
        $client->set_status('disabled', 'SYSTEM',
            "Tried tampering with transfer input for account transfer, illegal from [$loginid_from], to [$loginid_to]");
        $client->save;

        return $error_sub->(localize('The account transfer is unavailable for your account.'));
    }

    my %deposited = (
        $loginid_from => $client_from->default_account ? $client_from->default_account->currency_code : '',
        $loginid_to   => $client_to->default_account   ? $client_to->default_account->currency_code   : ''
    );

    if (not $deposited{$loginid_from} and not $deposited{$loginid_to}) {
        return $error_sub->(localize('The account transfer is unavailable. Please deposit to your account.'));
    }

    foreach my $c ($loginid_from, $loginid_to) {
        my $curr = $deposited{$c};
        if ($curr and $curr ne $currency) {
            return $error_sub->(localize('The account transfer is unavailable for accounts with different default currency.'));
        }
    }

    BOM::Platform::AuditLog::log("Account Transfer ATTEMPT, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    # error subs
    my $error_unfreeze_msg_sub = sub {
        my ($err, $client_message, @unfreeze) = @_;
        foreach my $loginid (@unfreeze) {
            BOM::Database::ClientDB->new({
                    client_loginid => $loginid,
                })->unfreeze;
        }

        BOM::Platform::AuditLog::log("Account Transfer FAILED, $err");

        $client_message ||= localize('An error occurred while processing request. If this error persists, please contact customer support');
        return $error_sub->($client_message);
    };
    my $error_unfreeze_sub = sub {
        my ($err, @unfreeze) = @_;
        $error_unfreeze_msg_sub->($err, '', @unfreeze);
    };

    my $err_msg      = "from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount], ";
    my $fm_client_db = BOM::Database::ClientDB->new({
        client_loginid => $client_from->loginid,
    });

    if (not $fm_client_db->freeze) {
        return $error_unfreeze_sub->("$err_msg error[Account stuck in previous transaction " . $client_from->loginid . ']');
    }
    my $to_client_db = BOM::Database::ClientDB->new({
        client_loginid => $client_to->loginid,
    });

    if (not $to_client_db->freeze) {
        return $error_unfreeze_sub->("$err_msg error[Account stuck in previous transaction " . $client_to->loginid . ']', $client_from->loginid);
    }

    my $err;
    try {
        $client_from->set_default_account($currency) || die "NO curr[$currency] for[$loginid_from]";
    }
    catch {
        $err = "$err_msg Wrong curr for $loginid_from [$_]";
    };
    if ($err) {
        return $error_unfreeze_sub->($err, $client_from->loginid, $client_to->loginid);
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
            $limit = $currency . ' ' . roundnear(0.01, $client_from->default_account->balance);
        } elsif ($err =~ /includes frozen bonus \[(.+)\]/) {
            my $frozen_bonus = $1;
            $limit = $currency . ' ' . roundnear(0.01, $client_from->default_account->balance - $frozen_bonus);
        } elsif ($err =~ /exceeds withdrawal limit \[(.+)\]\s+\((.+)\)/) {
            my $bal_1 = $1;
            my $bal_2 = $2;
            $limit = $bal_1;

            if ($bal_1 =~ /^([A-Z]{3})\s+/ and $1 ne $currency) {
                $limit .= " ($bal_2)";
            }
        }

        return $error_unfreeze_msg_sub->(
            "$err_msg validate_payment failed for $loginid_from [$err]",
            (defined $limit) ? "The maximum amount you may transfer is: $limit." : '',
            $client_from->loginid, $client_to->loginid
        );
    }

    try {
        $client_to->set_default_account($currency) || die "NO curr[$currency] for[$loginid_to]";
    }
    catch {
        $err = "$err_msg Wrong curr for $loginid_to [$_]";
    };
    if ($err) {
        return $error_unfreeze_sub->($err, $client_from->loginid, $client_to->loginid);
    }

    try {
        $client_to->validate_payment(
            currency => $currency,
            amount   => $amount,
        ) || die "validate_payment [$loginid_to]";
    }
    catch {
        $err = "$err_msg validate_payment failed for $loginid_to [$_]";
    };
    if ($err) {
        return $error_unfreeze_sub->($err, $client_from->loginid, $client_to->loginid);
    }

    my $response;
    try {
        $response = $client_from->payment_account_transfer(
            currency          => $currency,
            amount            => $amount,
            toClient          => $client_to,
            fmStaff           => $client_from->loginid,
            toStaff           => $client_to->loginid,
            remark            => 'Account transfer from ' . $client_from->loginid . ' to ' . $client_to->loginid,
            inter_db_transfer => 1,
            source            => $source,
        );
    }
    catch {
        $err = "$err_msg Account Transfer failed [$_]";
    };
    if ($err) {
        return $error_unfreeze_sub->($err);
    }

    BOM::Platform::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    $fm_client_db->unfreeze;
    $to_client_db->unfreeze;

    return {
        status              => 1,
        transaction_id      => $response->{transaction_id},
        client_to_full_name => $client_to->full_name,
        client_to_loginid   => $client_to->loginid
    };
}

sub topup_virtual {
    my $params = shift;

    my $client = $params->{client};
    my $source = $params->{source};

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
    my ($curr, $amount, $trx) = $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

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

1;

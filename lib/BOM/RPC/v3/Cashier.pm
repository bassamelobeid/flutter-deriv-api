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
use DataDog::DogStatsd::Helper qw(stats_inc stats_count);
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use BOM::RPC::v3::Utility;
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Client;
use BOM::Platform::Static::Config;
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency in_USD);
use BOM::Platform::Transaction;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;
use BOM::Platform::Email qw(send_email);
use BOM::System::AuditLog;

sub get_limits {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    if ($client->get_status('cashier_locked') or $client->documents_expired or $client->is_virtual) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'FeatureNotAvailable',
                message_to_client => localize('Sorry, this feature is not available.')});
    }

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = BOM::Platform::Runtime->instance->app_config->payments->withdrawal_limits->$landing_company;

    my $limit = +{
        map ({
                $_ => amount_from_to_currency($client->get_limit({'for' => $_}), 'USD', $client->currency);
            } (qw/account_balance daily_turnover payout/)),
        open_positions => $client->get_limit_for_open_positions,
    };

    my $numdays       = $wl_config->for_days;
    my $numdayslimit  = $wl_config->limit_for_days;
    my $lifetimelimit = $wl_config->lifetime_limit;

    if ($client->client_fully_authenticated) {
        $numdayslimit  = 99999999;
        $lifetimelimit = 99999999;
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
        $withdrawal_for_x_days = roundnear(0.01, amount_from_to_currency($withdrawal_for_x_days, $client->currency, 'EUR'));

        # withdrawal since inception
        my $withdrawal_since_inception = $payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']});
        $withdrawal_since_inception = roundnear(0.01, amount_from_to_currency($withdrawal_since_inception, $client->currency, 'EUR'));

        $limit->{withdrawal_since_inception_monetary} = to_monetary_number_format($withdrawal_since_inception, 1);
        $limit->{withdrawal_for_x_days_monetary}      = to_monetary_number_format($withdrawal_for_x_days,      $numdays);

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
    my ($language, $args) = ($params->{language}, $params->{args});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    my $broker_code = $client ? $client->broker_code : 'CR';

    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    my $countries = $payment_agent_mapper->get_all_authenticated_payment_agent_countries();

    # add country name plus code
    foreach (@{$countries}) {
        $_->[1] = BOM::Platform::Runtime->instance->countries->localized_code2country($_->[0], $language);
    }

    my $authenticated_paymentagent_agents =
        $payment_agent_mapper->get_authenticated_payment_agents({target_country => $args->{paymentagent_list}});

    my %payment_agent_banks = %{BOM::Platform::Locale::get_payment_agent_banks()};

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
    my ($loginid_fm, $website_name, $args) =
        ($params->{client_loginid}, $params->{website_name}, $params->{args});

    my $currency   = $args->{currency};
    my $amount     = $args->{amount};
    my $loginid_to = uc $args->{transfer_to};

    my $client_fm;
    if ($loginid_fm) {
        $client_fm = BOM::Platform::Client->new({loginid => $loginid_fm});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client_fm)) {
        return $auth_error;
    }

    my $payment_agent = $client_fm->payment_agent;

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
    my $app_config = BOM::Platform::Runtime->instance->app_config;
    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents)
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

    my $client_to = BOM::Platform::Client->new({loginid => $loginid_to});
    unless ($client_to) {
        return $reject_error_sub->(localize('Login ID ([_1]) does not exist.', $loginid_to));
    }

    if ($args->{dry_run}) {
        return {status => 2};
    }

    unless ($client_fm->landing_company->short eq $client_to->landing_company->short) {
        return $reject_error_sub->(localize('Cross-company payment agent transfers are not allowed.'));
    }

    for ($currency) {
        /^\w\w\w$/ || return $reject_error_sub->(localize('Sorry, the currency format is incorrect.'));
        /^USD$/    || return $reject_error_sub->(localize('Sorry, only USD is allowed.'));
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

    # freeze loginID to avoid a race condition
    if (not BOM::Platform::Transaction->freeze_client($loginid_fm)) {
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
            "Account stuck in previous transaction $loginid_fm"
        );
    }

    if (not BOM::Platform::Transaction->freeze_client($loginid_to)) {
        BOM::Platform::Transaction->unfreeze_client($loginid_fm);
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
    my $datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({client_loginid => $loginid_fm});
    my ($amount_transferred, $count) = $datamapper->get_today_payment_agent_withdrawal_sum_count;

    # maximum amount USD 100000 per day
    if (($amount_transferred + $amount) >= 100000) {
        BOM::Platform::Transaction->unfreeze_client($loginid_fm);
        BOM::Platform::Transaction->unfreeze_client($loginid_to);

        return $reject_error_sub->(localize('Sorry, you have exceeded the maximum allowable transfer amount for today.'));
    }

    # do not allow more than 1000 transactions per day
    if ($count > 1000) {
        BOM::Platform::Transaction->unfreeze_client($loginid_fm);
        BOM::Platform::Transaction->unfreeze_client($loginid_to);

        return $reject_error_sub->(localize('Sorry, you have exceeded the maximum allowable transactions for today.'));
    }

    # execute the transfer
    my $now       = Date::Utility->new;
    my $today     = $now->datetime_ddmmmyy_hhmmss_TZ;
    my $reference = Data::UUID->new()->create_str();
    my $comment =
        'Transfer from Payment Agent ' . $payment_agent->payment_agent_name . " to $loginid_to. Transaction reference: $reference. Timestamp: $today";

    $client_fm->payment_account_transfer(
        toClient => $client_to,
        currency => $currency,
        amount   => $amount,
        fmStaff  => $loginid_fm,
        toStaff  => $loginid_to,
        remark   => $comment,
    );

    BOM::Platform::Transaction->unfreeze_client($loginid_fm);
    BOM::Platform::Transaction->unfreeze_client($loginid_to);

    stats_count('business.usd_deposit.paymentagent', int(in_USD($amount, $currency) * 100));
    stats_inc('business.paymentagent');

    # sent email notification to client
    my $emailcontent = localize('Dear [_1] [_2] [_3],', $client_to->salutation, $client_to->first_name, $client_to->last_name,) . "\n\n" . localize(
        'We would like to inform you that the transfer of [_1] [_2] via [_3] has been processed.
The funds have been credited into your account.

Kind Regards,

The [_4] team.', $currency, $amount, $payment_agent->payment_agent_name, $website_name
    );

    send_email({
        'from'               => BOM::Platform::Static::Config::get_customer_support_email(),
        'to'                 => $client_to->email,
        'subject'            => localize('Acknowledgement of Money Transfer'),
        'message'            => [$emailcontent],
        'use_email_template' => 1,
        'template_loginid'   => $client_to->loginid
    });

    return {status => 1};
}

sub paymentagent_withdraw {
    my $params = shift;

    my ($client_loginid, $website_name, $args) =
        ($params->{client_loginid}, $params->{website_name}, $params->{args});

    my $client;
    if ($client_loginid) {
        $client = BOM::Platform::Client->new({loginid => $client_loginid});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    # expire token only when its not dry run
    if (exists $args->{dry_run} and not $args->{dry_run}) {
        unless (BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $client->email)) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => "InvalidVerificationCode",
                    message_to_client => localize("Your payment agent withdrawal token has expired.")});
        }
    }

    my $currency             = $args->{currency};
    my $amount               = $args->{amount};
    my $further_instruction  = $args->{description} // '';
    my $paymentagent_loginid = $args->{paymentagent_loginid};
    my $reference            = Data::UUID->new()->create_str();

    my $error_sub = sub {
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
        or $app_config->system->suspend->payment_agents)
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

    my $paymentagent = BOM::Platform::Client::PaymentAgent->new({'loginid' => $paymentagent_loginid})
        or return $error_sub->(localize('Sorry, the Payment Agent does not exist.'));

    if ($client->broker ne $paymentagent->broker) {
        return $error_sub->(localize('Sorry, the Payment Agent is unavailable for your region.'));
    }

    my $pa_client = $paymentagent->client;

    # check that the currency is in correct format
    if ($client->currency ne $currency) {
        return $error_sub->(localize('Sorry, your currency of [_1] is unavailable for Payment Agent Withdrawal', $client->currency));
    }

    if ($pa_client->currency ne $currency) {
        return $error_sub->(localize("Sorry, the Payment Agent's currency [_1] is unavailable for Payment Agent Withdrawal", $pa_client->currency));
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
        return {status => 2};
    }

    # freeze loginID to avoid a race condition
    if (not BOM::Platform::Transaction->freeze_client($client_loginid)) {
        return $error_sub->(
            localize('An error occurred while processing request. If this error persists, please contact customer support'),
            "Account stuck in previous transaction $client_loginid"
        );
    }

    if (not BOM::Platform::Transaction->freeze_client($paymentagent_loginid)) {
        BOM::Platform::Transaction->unfreeze_client($client_loginid);
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
    my $data_mapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
        client_loginid => $client_loginid,
        currency_code  => $currency,
    });
    my ($amount_transferred, $count) = $data_mapper->get_today_payment_agent_withdrawal_sum_count();

    # max withdrawal daily limit: weekday = $5000, weekend = $500
    my $daily_limit = (DateTime->now->day_of_week() > 5) ? 500 : 5000;

    if (($amount_transferred + $amount) > $daily_limit) {
        BOM::Platform::Transaction->unfreeze_client($client_loginid);
        BOM::Platform::Transaction->unfreeze_client($paymentagent_loginid);

        return $reject_error_sub->(
            localize('Sorry, you have exceeded the maximum allowable transfer amount [_1] for today.', $currency . $daily_limit));
    }

    if ($amount_transferred > 1500) {
        my $support = BOM::Platform::Static::Config::get_customer_support_email();
        my $message = "Client $client_loginid transferred \$$amount_transferred to payment agent today";
        send_email({
            from    => $support,
            to      => $support,
            subject => $message,
            message => [$message],
        });
    }

    # do not allowed more than 20 transactions per day
    if ($count > 20) {
        BOM::Platform::Transaction->unfreeze_client($client_loginid);
        BOM::Platform::Transaction->unfreeze_client($paymentagent_loginid);

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
        . Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ
        . '. Client note: '
        . $further_instruction;

    # execute the transfer.
    $client->payment_account_transfer(
        currency => $currency,
        amount   => $amount,
        remark   => $comment,
        fmStaff  => $client_loginid,
        toStaff  => $paymentagent_loginid,
        toClient => $pa_client,
    );

    BOM::Platform::Transaction->unfreeze_client($client_loginid);
    BOM::Platform::Transaction->unfreeze_client($paymentagent_loginid);

    my $client_name = $client->first_name . ' ' . $client->last_name;
    # sent email notification to Payment Agent
    my $emailcontent = [
        localize('Dear [_1] [_2] [_3],', $pa_client->salutation, $pa_client->first_name, $pa_client->last_name),
        '',
        localize(
            'We would like to inform you that the withdrawal request of [_1][_2] by [_3] [_4] has been processed. The funds have been credited into your account [_5] at [_6].',
            $currency, $amount, $client_name, $client_loginid, $paymentagent_loginid, $website_name
        ),
        '',
        $further_instruction,
        '',
        localize('Kind Regards,'),
        '',
        localize('The [_1] team.', $website_name),
    ];
    send_email({
        from               => BOM::Platform::Static::Config::get_customer_support_email(),
        to                 => $paymentagent->email,
        subject            => localize('Acknowledgement of Withdrawal Request'),
        message            => $emailcontent,
        use_email_template => 1,
    });

    return {status => 1};
}

sub __output_payments_error_message {
    my $args           = shift;
    my $client         = $args->{'client'};
    my $action         = $args->{'action'};
    my $payment_type   = $args->{'payment_type'} || 'n/a';                                # used for reporting; if not given, not applicable
    my $currency       = $args->{'currency'};
    my $amount         = $args->{'amount'};
    my $error_message  = $args->{'error_msg'};
    my $payments_email = BOM::Platform::Runtime->instance->app_config->payments->email;
    my $cs_email       = BOM::Platform::Static::Config::get_customer_support_email();

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
    my $amount   = $arg_ref->{'amount'};
    my $error    = $arg_ref->{'error'};
    my $currency = $client->currency;

    my $balance = $client->default_account ? to_monetary_number_format($client->default_account->balance) : 0;
    if ($error =~ /exceeds client balance/) {
        return (localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $currency, $balance));
    }

    my $withdrawal_limits = $client->get_withdrawal_limits();

    # At this point, the Client is not allowed to withdraw. Return error message.
    my $error_message = localize('Your account balance is [_1] [_2]. Maximum withdrawal by all other means is [_1] [_3].',
        $currency, $balance, $withdrawal_limits->{'max_withdrawal'});

    if ($withdrawal_limits->{'frozen_free_gift'} > 0) {
        # Insert turnover limit as a parameter depends on the promocode type
        $error_message .= localize(
            'Note: You will be able to withdraw your bonus of [_1][_2] only once your aggregate volume of trades exceeds [_1][_3]. This restriction applies only to the bonus and profits derived therefrom.  All other deposits and profits derived therefrom can be withdrawn at any time.',
            $currency,
            $withdrawal_limits->{'frozen_free_gift'},
            $withdrawal_limits->{'free_gift_turnover_limit'});
    }

    return ($error_message, "Client $client is not allowed to withdraw");
}

## This endpoint is only available for MLT/MF accounts
sub transfer_between_accounts {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $error_sub = sub {
        my ($message_to_client, $message) = @_;
        BOM::RPC::v3::Utility::create_error({
            code              => 'TransferBetweenAccountsError',
            message_to_client => $message_to_client,
            ($message) ? (message => $message) : (),
        });
    };

    if ($client->get_status('disabled') or $client->get_status('cashier_locked') or $client->get_status('withdrawal_locked')) {
        return $error_sub->(localize('The account transfer is unavailable for your account: [_1].', $client->loginid));
    }

    my $args         = $params->{args};
    my $loginid_from = $args->{account_from};
    my $loginid_to   = $args->{account_to};
    my $currency     = $args->{currency};
    my $amount       = $args->{amount};

    my %siblings = map { $_->loginid => $_ } $client->siblings;

    # get clients
    unless ($loginid_from and $loginid_to and $currency and $amount) {
        my @accounts;
        foreach my $account (values %siblings) {
            next unless (grep { $account->landing_company->short eq $_ } ('malta', 'maltainvest'));
            push @accounts,
                {
                loginid  => $account->loginid,
                balance  => $account->default_account ? $account->default_account->balance : 0,
                currency => $account->default_account ? $account->default_account->currency_code : '',
                };
        }
        return {
            status   => 0,
            accounts => \@accounts
        };
    }

    if (not looks_like_number($amount) or $amount < 0.1 or $amount !~ /^\d+.?\d{0,2}$/) {
        return $error_sub->(localize('Invalid amount. Minimum transfer amount is 0.10, and up to 2 decimal places.'));
    }

    my $err_msg = "from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount], ";

    my $is_good = 0;
    if ($siblings{$loginid_from} && $siblings{$loginid_to}) {
        my %landing_companies = (
            $siblings{$loginid_from}->landing_company->short => 1,
            $siblings{$loginid_to}->landing_company->short   => 1,
        );

        # check for transfer between malta & maltainvest
        $is_good = $landing_companies{malta} && $landing_companies{maltainvest};
    }

    unless ($is_good) {
        # $c->app->log->warn("DISABLED " . $client->loginid . ". Tried tampering with transfer input for account transfer. $err_msg");
        $client->set_status('disabled', 'SYSTEM',
            "Tried tampering with transfer input for account transfer, illegal from [$loginid_from], to [$loginid_to]");
        $client->save;

        return $error_sub->(localize('The account transfer is unavailable for your account.'));
    }

    my $client_from = $siblings{$loginid_from};
    my $client_to   = $siblings{$loginid_to};

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

    BOM::System::AuditLog::log("Account Transfer ATTEMPT, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    # error subs
    my $error_unfreeze_msg_sub = sub {
        my ($err, $client_message, @unfreeze) = @_;
        foreach my $loginid (@unfreeze) {
            BOM::Platform::Transaction->unfreeze_client($loginid);
        }

        BOM::System::AuditLog::log("Account Transfer FAILED, $err");

        $client_message ||= localize('An error occurred while processing request. If this error persists, please contact customer support');
        return $error_sub->($client_message);
    };
    my $error_unfreeze_sub = sub {
        my ($err, @unfreeze) = @_;
        $error_unfreeze_msg_sub->($err, '', @unfreeze);
    };

    if (not BOM::Platform::Transaction->freeze_client($client_from->loginid)) {
        return $error_unfreeze_sub->("$err_msg error[Account stuck in previous transaction " . $client_from->loginid . ']');
    }
    if (not BOM::Platform::Transaction->freeze_client($client_to->loginid)) {
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
            $limit = $currency . ' ' . to_monetary_number_format($client_from->default_account->balance);
        } elsif ($err =~ /includes frozen bonus \[(.+)\]/) {
            my $frozen_bonus = $1;
            $limit = $currency . ' ' . to_monetary_number_format($client_from->default_account->balance - $frozen_bonus);
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

    try {
        $client_from->payment_account_transfer(
            currency          => $currency,
            amount            => $amount,
            toClient          => $client_to,
            fmStaff           => $client_from->loginid,
            toStaff           => $client_to->loginid,
            remark            => 'Account transfer from ' . $client_from->loginid . ' to ' . $client_to->loginid,
            inter_db_transfer => 1,
        );
    }
    catch {
        $err = "$err_msg Account Transfer failed [$_]";
    };
    if ($err) {
        return $error_unfreeze_sub->($err);
    }

    BOM::System::AuditLog::log("Account Transfer SUCCESS, from[$loginid_from], to[$loginid_to], curr[$currency], amount[$amount]", $loginid_from);

    BOM::Platform::Transaction->unfreeze_client($client_from->loginid);
    BOM::Platform::Transaction->unfreeze_client($client_to->loginid);

    return {status => 1};
}

sub topup_virtual {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

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
    if ($client->default_account->balance > BOM::Platform::Runtime->instance->app_config->payments->virtual->minimum_topup_balance->$currency) {
        return $error_sub->(localize('Your balance is higher than the permitted amount.'));
    }

    if (scalar($client->open_bets)) {
        return $error_sub->(localize('Sorry, you have open positions. Please close out all open positions before requesting additional funds.'));
    }

    # CREDIT HIM WITH THE MONEY
    my ($curr, $amount, $trx) = $client->deposit_virtual_funds;

    return {
        amount   => $amount,
        currency => $curr
    };
}

1;

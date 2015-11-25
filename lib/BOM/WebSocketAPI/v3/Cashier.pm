package BOM::WebSocketAPI::v3::Cashier;

use strict;
use warnings;

use HTML::Entities;
use List::Util qw( min first );
use Data::UUID;
use Path::Tiny;
use DateTime;
use Date::Utility;
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc stats_count);
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use BOM::WebSocketAPI::v3::Utility;
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency in_USD);
use BOM::Platform::Transaction;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::PaymentAgent;
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;
use BOM::Platform::Email qw(send_email);

sub get_limits {
    my ($client, $config) = @_;

    # check if Client is not in lock cashier and not virtual account
    unless (not $client->get_status('cashier_locked') and not $client->documents_expired and $client->broker !~ /^VRT/) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'FeatureNotAvailable',
                message_to_client => BOM::Platform::Context::localize('Sorry, this feature is not available.')});
    }

    my $limit = +{
        map ({
                $_ => amount_from_to_currency($client->get_limit({'for' => $_}), 'USD', $client->currency);
            } (qw/account_balance daily_turnover payout/)),
        open_positions => $client->get_limit_for_open_positions,
    };

    my $numdays       = $config->for_days;
    my $numdayslimit  = $config->limit_for_days;
    my $lifetimelimit = $config->lifetime_limit;

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
    my ($client, $language, $args) = @_;

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

sub paymentagent_withdraw {
    my ($client, $app_config, $website, $args) = @_;

    my $currency = $args->{currency};
    my $amount   = $args->{amount};

    if (   $app_config->system->suspend->payments
        or $app_config->system->suspend->payment_agents)
    {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize(
                    'Sorry, the Payment Agent Withdrawal is temporarily disabled due to system maintenance. Please try again in 30 minutes.')});
    } elsif (not $client->landing_company->allows_payment_agents) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize('Payment Agents are not available on this site.')});
    } elsif (not $client->allow_paymentagent_withdrawal()) {
        # check whether allow to withdraw via payment agent
        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            action       => 'Withdrawal via payment agent, client [' . $client->loginid . ']',
            error_msg    => BOM::Platform::Context::localize('You are not authorized for withdrawal via payment agent.'),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
    } elsif ($client->cashier_setting_password) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize('Your cashier is locked as per your request.')});
    }

    my $authenticated_pa;
    if ($client->residence) {
        my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $client->broker});
        $authenticated_pa = $payment_agent_mapper->get_authenticated_payment_agents({target_country => $client->residence});
    }

    if (not $client->residence or scalar keys %{$authenticated_pa} == 0) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize('The Payment Agent facility is currently not available in your country.')});
    }

    ## validate amount
    if ($amount < 10 || $amount > 2000) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize('Invalid amount. minimum is 10, maximum is 2000.')});
    }

    my $further_instruction  = $args->{description} // '';
    my $paymentagent_loginid = $args->{paymentagent_loginid};
    my $reference            = Data::UUID->new()->create_str();
    my $client_loginid       = $client->loginid;

    my $paymentagent = BOM::Platform::Client::PaymentAgent->new({'loginid' => $paymentagent_loginid})
        or return BOM::WebSocketAPI::v3::Utility::create_error({
            code              => 'PaymentAgentWithdrawError',
            message_to_client => BOM::Platform::Context::localize('Sorry, the Payment Agent does not exist.')});

    if ($client->broker ne $paymentagent->broker) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize('Sorry, the Payment Agent is unavailable for your region.')});
    }

    my $pa_client = $paymentagent->client;

    # check that the currency is in correct format
    if ($client->currency ne $currency) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code => 'PaymentAgentWithdrawError',
                message_to_client =>
                    BOM::Platform::Context::localize('Sorry, your currency of [_1] is unavailable for Payment Agent Withdrawal', $client->currency)});
    }

    if ($pa_client->currency ne $currency) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize(
                    "Sorry, the Payment Agent's currency [_1] is unavailable for Payment Agent Withdrawal",
                    $pa_client->currency
                )});
    }

    # check that the amount is in correct format
    if ($amount !~ /^\d*\.?\d*$/) {
        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
            error_msg    => BOM::Platform::Context::localize('There was an error processing the request.'),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
    }

    # check that the additional information does not exceeded the allowed limits
    if (length($further_instruction) > 300) {
        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
            error_msg    => BOM::Platform::Context::localize('Further instructions must not exceed [_1] characters.', 300),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
    }

    # check that both the client payment agent cashier is not locked
    if ($client->get_status('cashier_locked') || $client->get_status('withdrawal_locked') || $client->documents_expired) {
        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
            error_msg    => BOM::Platform::Context::localize('There was an error processing the request.'),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
    }
    if ($pa_client->get_status('cashier_locked') || $client->documents_expired) {
        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
            error_msg    => BOM::Platform::Context::localize('This Payment Agent cashier section is locked.'),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
    }

    if ($args->{dry_run}) {
        return 2;
    }

    # freeze loginID to avoid a race condition
    if (not BOM::Platform::Transaction->freeze_client($client_loginid)) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize(
                    'An error occurred while processing request. If this error persists, please contact customer support'),
                message => "Account stuck in previous transaction $client_loginid"
            });
    }
    if (not BOM::Platform::Transaction->freeze_client($paymentagent_loginid)) {
        BOM::Platform::Transaction->unfreeze_client($client_loginid);
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'PaymentAgentWithdrawError',
                message_to_client => BOM::Platform::Context::localize(
                    'An error occurred while processing request. If this error persists, please contact customer support'),
                message => "Account stuck in previous transaction $paymentagent_loginid"
            });
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
        return __client_withdrawal_notes({
            client => $client,
            amount => $amount,
            error  => $withdraw_error
        });
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

        return __output_payments_error_message({
                client    => $client,
                website   => $website,
                action    => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
                error_msg => BOM::Platform::Context::localize(
                    'Sorry, you have exceeded the maximum allowable transfer amount [_1] for today.',
                    $currency . $daily_limit
                ),
                payment_type => 'Payment Agent Withdrawal',
                currency     => $currency,
                amount       => $amount,
            });
    }

    if ($amount_transferred > 1500) {
        my $support = $website->config->get('customer_support.email');
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

        return __output_payments_error_message({
            client       => $client,
            website      => $website,
            website      => $website,
            action       => 'Withdraw - from ' . $client_loginid . ' to Payment Agent ' . $paymentagent_loginid,
            error_msg    => BOM::Platform::Context::localize('Sorry, you have exceeded the maximum allowable transactions for today.'),
            payment_type => 'Payment Agent Withdrawal',
            currency     => $currency,
            amount       => $amount,
        });
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
    my $clientmessage = [
        BOM::Platform::Context::localize('Dear [_1] [_2] [_3],', $pa_client->salutation, $pa_client->first_name, $pa_client->last_name),
        '',
        BOM::Platform::Context::localize(
            'We would like to inform you that the withdrawal request of [_1][_2] by [_3] [_4] has been processed. The funds have been credited into your account [_5] at [_6].',
            $currency, $amount, $client_name, $client_loginid, $paymentagent_loginid, $website->display_name
        ),
        '',
        $further_instruction,
        '',
        BOM::Platform::Context::localize('Kind Regards,'),
        '',
        BOM::Platform::Context::localize('The [_1] team.', $website->display_name),
    ];
    send_email({
        from               => $website->config->get('customer_support.email'),
        to                 => $paymentagent->email,
        subject            => BOM::Platform::Context::localize('Acknowledgement of Withdrawal Request'),
        message            => $clientmessage,
        use_email_template => 1,
    });

    return 1;
}

sub __output_payments_error_message {
    my $args         = shift;
    my $client       = $args->{'client'};
    my $website      = $args->{'website'};
    my $action       = $args->{'action'};
    my $error_code   = $args->{'error_code'};
    my $payment_type = $args->{'payment_type'} || 'n/a';    # used for reporting; if not given, not applicable
    my $currency     = $args->{'currency'};
    my $amount       = $args->{'amount'};
    my $error_msg    = $args->{'error_msg'};
    my $hide_options = $args->{'hide_options'};

    my $email_msg = $error_msg;
    $email_msg =~ s/<br\s*\/?>/\n/ig;
    $email_msg =~ s/<[^>]+>/$1/ig;

    my $error_message = ($error_msg) ? $error_msg : BOM::Platform::Context::localize('Sorry, your payment could not be processed at this time.');

    my $error_message_with_code = '';
    if ($error_code) {
        $error_message_with_code =
            BOM::Platform::Context::localize('Mentioning error code [_1] in any correspondence may help us resolve the issue more quickly.',
            $error_code);
    }

    # amount is not always exist because error may happen before client submit the form
    # or when redirected from 3rd party site to failure script where no data is returned
    my $email_amount = $amount ? "Amount : $currency $amount" : '';

    my $now     = Date::Utility->new;
    my $message = [
        "Details of the payment error :\n",
        "Date/Time : " . $now->datetime,
        "Action : " . ucfirst $action . " via $payment_type",
        "Login ID : " . $client->loginid,
        $email_amount,
        "Error message : $email_msg $error_message_with_code",
    ];
    my $email_from = $website->config->get('customer_support.email');

    send_email({
        from    => $email_from,
        to      => $app_config->payments->email,
        subject => 'Payment Error: ' . $payment_type . ' [' . $client->loginid . ']',
        message => $message,
    });

    # write error to deposit-failure.log
    if ($action eq 'deposit') {
        Path::Tiny::path('/var/log/fixedodds/deposit-error.log')
            ->append($now->datetime
                . ' LoginID:'
                . $client->loginid
                . ' Method:'
                . $payment_type
                . ' Amount:'
                . $currency
                . $amount
                . ' Error:'
                . $email_msg . ' '
                . $error_message_with_code);
    }

    return BOM::WebSocketAPI::v3::Utility::create_error({
        code              => 'PaymentAgentWithdrawError',
        message_to_client => "$error_message $error_message_with_code"
    });
}

sub __client_withdrawal_notes {
    my $arg_ref  = shift;
    my $client   = $arg_ref->{'client'};
    my $amount   = $arg_ref->{'amount'};
    my $error    = $arg_ref->{'error'};
    my $currency = $client->currency;

    my $balance = $client->default_account ? $client->default_account->balance : 0;
    if ($error =~ /exceeds client balance/) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code => 'PaymentAgentWithdrawError',
                message_to_client =>
                    BOM::Platform::Context::localize('Sorry, you cannot withdraw. Your account balance is [_1] [_2].', $currency, $balance)});
    }

    my $withdrawal_limits = $client->get_withdrawal_limits();

    # At this point, the Client is not allowed to withdraw. Return error message.
    my $error_message = BOM::Platform::Context::localize('Your account balance is [_1] [_2]. Maximum withdrawal by all other means is [_1] [_3].',
        $currency, $balance, $withdrawal_limits->{'max_withdrawal'});

    if ($withdrawal_limits->{'frozen_free_gift'} > 0) {
        # Insert turnover limit as a parameter depends on the promocode type
        $error_message .= BOM::Platform::Context::localize(
            'Note: You will be able to withdraw your bonus of [_1][_2] only once your aggregate volume of trades exceeds [_1][_3]. This restriction applies only to the bonus and profits derived therefrom.  All other deposits and profits derived therefrom can be withdrawn at any time.',
            $currency,
            $withdrawal_limits->{'frozen_free_gift'},
            $withdrawal_limits->{'free_gift_turnover_limit'});
    }

    return BOM::WebSocketAPI::v3::Utility::create_error({
        code              => 'PaymentAgentWithdrawError',
        message_to_client => $error_message,
        message           => "Client $client is not allowed to withdraw"
    });
}

1;

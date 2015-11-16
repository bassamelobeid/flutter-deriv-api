package BOM::WebSocketAPI::v3::Cashier;

use strict;
use warnings;

use List::Util qw( min first );
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use BOM::Platform::Runtime;
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency in_USD);
use BOM::Platform::Context qw(localize request);

sub get_limits {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');

    BOM::Platform::Context::request($c->stash('request'));

    # check if Client is not in lock cashier and not virtual account
    unless (not $client->get_status('cashier_locked') and not $client->documents_expired and $client->broker !~ /^VRT/) {
        return $c->new_error('get_limits', 'FeatureNotAvailable', localize('Sorry, this feature is not available.'));
    }

    my $limit = +{
        map ({
                $_ => amount_from_to_currency($client->get_limit({'for' => $_}), 'USD', $client->currency);
            } (qw/account_balance daily_turnover payout/)),
        open_positions => $client->get_limit_for_open_positions,
    };

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = $c->app_config->payments->withdrawal_limits->$landing_company;
    my $numdays         = $wl_config->for_days;
    my $numdayslimit    = $wl_config->limit_for_days;
    my $lifetimelimit   = $wl_config->lifetime_limit;

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

    return {
        msg_type   => 'get_limits',
        get_limits => $limit,
    };
}

sub paymentagent_withdraw {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');
    my $currency = $args->{currency};
    my $amount   = $args->{amount};

    if (   $c->app_config->system->suspend->payments
        or $c->app_config->system->suspend->payment_agents)
    {
        return $c->new_error('paymentagent_withdraw', 'PaymentAgentWithdrawError', localize('Sorry, the Payment Agent Withdrawal is temporarily disabled due to system maintenance. Please try again in 30 minutes.'));
    } elsif (not $client->landing_company->allows_payment_agents) {
        return $c->new_error('paymentagent_withdraw', 'PaymentAgentWithdrawError', localize('Payment Agents are not available on this site.'));
    } elsif (not $client->allow_paymentagent_withdrawal()) {
        # check whether allow to withdraw via payment agent
        return __output_payments_error_message(
            $c,
            {
                client       => $client,
                action       => 'Withdrawal via payment agent, client [' . $client->loginid . ']',
                error_msg    => localize('You are not authorized for withdrawal via payment agent.'),
                payment_type => 'Payment Agent Withdrawal',
                currency     => $currency,
                amount       => $amount,
            });
    } elsif ($client->cashier_setting_password) {
        return $c->new_error('paymentagent_withdraw', 'PaymentAgentWithdrawError', localize('Your cashier is locked as per your request.'));
    }




}

sub __output_payments_error_message {
    my $c            = shift;
    my $args         = shift;
    my $r            = $c->stash('request');
    my $client       = $args->{'client'};
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

    my $error_message = ($error_msg) ? $error_msg : localize('Sorry, your payment could not be processed at this time.');

    my $error_message_with_code = '';
    if ($error_code) {
        $error_message_with_code = localize('Mentioning error code [_1] in any correspondence may help us resolve the issue more quickly.', $error_code);
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
    my $email_from = $r->website->config->get('customer_support.email');

    send_email({
        from    => $email_from,
        to      => $c->app_config->payments->email,
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

    return $c->new_error('paymentagent_withdraw', 'PaymentAgentWithdrawError', "$error_message $error_message_with_code");
}

1;

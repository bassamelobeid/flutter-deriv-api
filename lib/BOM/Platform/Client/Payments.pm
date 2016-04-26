## no critic (RequireFilenameMatchesPackage)

package BOM::Platform::Client;

use strict;
use warnings;

use Try::Tiny;
use DateTime;
use List::Util qw(min);

use BOM::Utility::CurrencyConverter qw(amount_from_to_currency);
use BOM::Platform::Client::IDAuthentication;
use DataDog::DogStatsd::Helper qw(stats_inc stats_count);
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

# NOTE.. this is a 'mix-in' of extra subs for BOM::Platform::Client.  It is not a distinct Class.

#######################################
sub validate_payment {
    my ($self, %args) = @_;
    my $currency = $args{currency} || die "no currency";
    my $amount   = $args{amount}   || die "no amount";

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->default_account || die "no account";
    my $accbal  = $account->load->balance;                      # forces db-read to get very latest
    my $acccur  = $account->currency_code;
    my $absamt  = abs($amount);

    die "Payments are suspended.\n"
        if BOM::Platform::Runtime->instance->app_config->system->suspend->payments;

    die "Client\'s cashier is locked.\n"
        if $self->get_status('cashier_locked');

    die "Client is disabled.\n"
        if $self->get_status('disabled');

    die "Client has set the cashier password.\n" if $self->cashier_setting_password;

    die "Payment currency [$currency] not client currency [$acccur].\n"
        if $currency ne $acccur;

    if ($action_type eq 'deposit') {
        die "Deposits blocked for this Client.\n"
            if $self->get_status('unwelcome');

        if (    $self->broker_code eq 'MLT'
            and $self->is_first_deposit_pending
            and $args{payment_type} eq 'affiliate_reward')
        {
            $self->{mlt_affiliate_first_deposit} = 1;
        }

        my $max_balance = $self->get_limit({'for' => 'account_balance'});
        die "Balance would exceed $max_balance limit\n"
            if ($amount + $accbal) > $max_balance;
    }

    if ($action_type eq 'withdrawal') {

        die "Withdrawal is disabled.\n"
            if $self->get_status('withdrawal_locked');

        die "Withdrawal amount [$currency $absamt] exceeds client balance [$currency $accbal].\n"
            if $absamt > $accbal;

        if (my $frozen = $self->get_withdrawal_limits->{frozen_free_gift}) {
            my $unfrozen = sprintf '%.2f', $accbal - $frozen;
            die sprintf "Withdrawal is [%s %s] but balance [%s] includes frozen bonus [%.2f].\n", $currency, $absamt, $accbal, $frozen
                if $absamt > $unfrozen;
        }

        return 1 if $self->client_fully_authenticated;

        my $lc = $self->landing_company->short;
        my $lc_limits;
        my $withdrawal_limits = BOM::Platform::Runtime->instance->app_config->payments->withdrawal_limits;
        #Kaveh said we should refacoted ....withdrawal_limits->$lc to this
        if ($lc eq 'costarica') {
            $lc_limits = $withdrawal_limits->costarica;
        } elsif ($lc eq 'iom') {
            $lc_limits = $withdrawal_limits->iom;
        } elsif ($lc eq 'malta') {
            $lc_limits = $withdrawal_limits->malta;
        } elsif ($lc eq 'maltainvest') {
            $lc_limits = $withdrawal_limits->maltainvest;
        } elsif ($lc eq 'japan') {
            $lc_limits = $withdrawal_limits->japan;
        } else {
            die "Invalid landing company - $lc\n";
        }

        # for CR & JP, only check for lifetime limits (in client's currency)
        if ($lc eq 'costarica' or $lc eq 'japan') {
            my $wd_epoch = $account->find_payment(
                select => '-sum(amount) as amount',
                query  => [
                    amount               => {lt => 0},
                    payment_gateway_code => {ne => 'currency_conversion_transfer'}
                ],
                )->[0]->amount
                || 0;

            my $wd_left = $lc_limits->lifetime_limit - $wd_epoch;

            # avoids obscure rounding errors after currency conversion
            if ($absamt > $wd_left + 0.001) {
                die sprintf "Withdrawal amount [%s %.2f] exceeds withdrawal limit [%s %.2f].\n", $currency, $absamt, $currency, $wd_left;
            }
        } else {
            my $for_days = $lc_limits->for_days;
            my $since = DateTime->now->subtract(days => $for_days);

            my $wd_eur_since_limit = $lc_limits->limit_for_days;
            my $wd_eur_epoch_limit = $lc_limits->lifetime_limit;

            my %wd_query = (
                amount               => {lt => 0},
                payment_gateway_code => {ne => 'currency_conversion_transfer'});

            my $wd_epoch = $account->find_payment(
                select => '-sum(amount) as amount',
                query  => [%wd_query],
                )->[0]->amount
                || 0;

            my $wd_since = $account->find_payment(
                select => '-sum(amount) as amount',
                query  => [%wd_query, payment_time => {gt => $since}],
                )->[0]->amount
                || 0;

            my $wd_eur_since = amount_from_to_currency($wd_since, $currency, 'EUR');
            my $wd_eur_epoch = amount_from_to_currency($wd_epoch, $currency, 'EUR');

            #printf STDERR "total_withdrawal since $since ($for_days days ago) is %s / %s.\n", $wd_since, $wd_eur_since;
            #printf STDERR "total_withdrawal since epoch                       is %s / %s.\n", $wd_epoch, $wd_eur_epoch;
            #printf STDERR "limits for $lc are $wd_eur_since_limit / $wd_eur_epoch_limit.\n";

            my $wd_eur_since_left = $wd_eur_since_limit - $wd_eur_since;
            my $wd_eur_epoch_left = $wd_eur_epoch_limit - $wd_eur_epoch;

            my $wd_eur_left = min($wd_eur_since_left, $wd_eur_epoch_left);
            my $wd_left = amount_from_to_currency($wd_eur_left, 'EUR', $currency);

            # avoids obscure rounding errors after currency conversion
            if ($absamt > $wd_left + 0.001) {
                die sprintf "Withdrawal amount [%s %.2f] exceeds withdrawal limit [EUR %.2f] (%s %.2f).\n",
                    $currency, $absamt, $wd_eur_left, $currency, $wd_left;
            }
        }

    }

    return 1;
}

#######################################
sub deposit_virtual_funds {
    my $self = shift;
    $self->is_virtual || die "not a virtual client";

    my $currency = (($self->default_account and $self->default_account->currency_code eq 'JPY') or $self->residence eq 'jp') ? 'JPY' : 'USD';
    my $amount = BOM::Platform::Runtime->instance->app_config->payments->virtual->topup_amount->$currency;

    my $trx = $self->payment_legacy_payment(
        currency     => $currency,
        amount       => $amount,
        payment_type => 'virtual_credit',
        remark       => 'Virtual money credit to account',
    );
    return ($currency, $amount, $trx);
}

#######################################
# PAYMENT HANDLERS
# These Payment handlers are each named as payment_{payment_gateway_code}
# where each {payment_gateway_code} is a subclass of payment and is a 1-to-1 table.

# 'smart_payment' is a one-stop shop which will validate, and choose the appropriate
# payment_gateway, based on the payment_type.  Its skip_validation flag is only for
# some legacy tests which assume that the balance already got out of range somehow.
#######################################

sub smart_payment {
    my ($self, %args) = @_;
    my $payment_type = $args{payment_type} || die "no payment_type";
    my $payment_gateway_code = $args{payment_gateway_code};

    $self->validate_payment(%args) unless delete $args{skip_validation};

    # each 'payment_type' implies a 'payment_gateway'..
    my %gateway_map = (
        affiliate_reward    => 'affiliate_reward',
        external_cashier    => 'doughflow',
        free_gift           => 'free_gift',
        adjustment          => 'legacy_payment',
        adjustment_purchase => 'legacy_payment',
        adjustment_sale     => 'legacy_payment',
        dormant_fee         => 'payment_fee',
        payment_fee         => 'payment_fee',
        bank_money_transfer => 'bank_wire',
        cash_transfer       => 'western_union',      # ! need to fix in db first
    );

    $payment_gateway_code ||= $gateway_map{$payment_type}
        || die "unsupported payment_type: $payment_type";
    my $payment_handler = "payment_$payment_gateway_code";
    return $self->$payment_handler(%args);
}

#######################################
sub payment_legacy_payment {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark ";
    my $payment_type = $args{payment_type} || die "no payment_type";
    my $staff        = $args{staff}        || 'system';

    # these are only here to support some tests which set up historic payments :(
    my $payment_time     = delete $args{payment_time};
    my $transaction_time = delete $args{transaction_time};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'legacy_payment',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
        ($payment_time ? (payment_time => $payment_time) : ()),
    });
    $payment->legacy_payment({legacy_type => $payment_type});
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
        ($transaction_time ? (transaction_time => $transaction_time) : ()),
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;
    return $trx;
}

#######################################
sub payment_bank_wire {
    my ($self, %args) = @_;

    my $currency = delete $args{currency} || die "no currency";
    my $amount   = delete $args{amount}   || die "no amount";
    my $staff    = delete $args{staff}    || 'system';
    my $remark   = delete $args{remark}   || '';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my %bank_wire_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::BankWire->meta->column($_) }
        keys %args;

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'bank_wire',
        payment_type_code    => 'bank_money_transfer',
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });
    $payment->bank_wire(\%bank_wire_values);
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;
    return $trx;
}

#######################################
sub payment_account_transfer {
    my ($fmClient, %args) = @_;

    my $toClient = delete $args{toClient} || die "no toClient";
    my $currency = delete $args{currency} || die "no currency";
    my $amount   = delete $args{amount}   || die "no amount";
    my $staff    = delete $args{staff}    || 'system';
    my $toStaff  = delete $args{toStaff}  || $staff;
    my $fmStaff  = delete $args{fmStaff}  || $staff;
    my $remark   = delete $args{remark};
    my $toRemark = delete $args{toRemark} || $remark || ("Transfer from " . $fmClient->loginid);
    my $fmRemark = delete $args{fmRemark} || $remark || ("Transfer to " . $toClient->loginid);

    my $fmAccount = $fmClient->set_default_account($currency);
    my $toAccount = $toClient->set_default_account($currency);

    my $inter_db_transfer;
    $inter_db_transfer = delete $args{inter_db_transfer} if (exists $args{inter_db_transfer});

    unless ($inter_db_transfer) {
        # here we rely on ->set_default_account above
        # which makes sure the `write` database is used.
        my $dbh = $fmClient->db->dbh;
        my $response;
        try {
            my $sth = $dbh->prepare('SELECT (v_from_trans).id FROM payment.payment_account_transfer(?,?,?,?,?,?,?,?,NULL)');
            $sth->execute($fmClient->loginid, $toClient->loginid, $currency, $amount, $fmStaff, $toStaff, $fmRemark, $toRemark);
            my $records = $sth->fetchall_arrayref({});
            if (scalar @{$records}) {
                $response->{transaction_id} = $records->[0]->{id};
            }
        }
        catch {
            if (ref eq 'ARRAY') {
                die "@$_";
            } else {
                die $_;
            }
        };
        return $response;
    }

    my $gateway_code = 'account_transfer';

    my ($fmPayment) = $fmAccount->add_payment({
        amount               => -$amount,
        payment_gateway_code => $gateway_code,
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $fmStaff,
        remark               => $fmRemark,
    });
    my ($toPayment) = $toAccount->add_payment({
        amount               => $amount,
        payment_gateway_code => $gateway_code,
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $toStaff,
        remark               => $toRemark,
    });
    my ($fmTrx) = $fmPayment->add_transaction({
        account_id    => $fmAccount->id,
        amount        => -$amount,
        staff_loginid => $fmStaff,
        referrer_type => 'payment',
        action_type   => 'withdrawal',
        quantity      => 1,
    });
    my ($toTrx) = $toPayment->add_transaction({
        account_id    => $toAccount->id,
        amount        => $amount,
        staff_loginid => $toStaff,
        referrer_type => 'payment',
        action_type   => 'deposit',
        quantity      => 1,
    });

    $fmAccount->save(cascade => 1);
    $fmPayment->save(cascade => 1);

    $toAccount->save(cascade => 1);
    $toPayment->save(cascade => 1);

    return {transaction_id => $fmTrx->id};
}

#######################################
sub payment_affiliate_reward {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'affiliate_reward';
    my $staff        = $args{staff}        || 'system';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'affiliate_reward',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });
    $payment->affiliate_reward({});
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;

    if (exists $self->{mlt_affiliate_first_deposit} and $self->{mlt_affiliate_first_deposit}) {
        $self->set_status('cashier_locked', 'system', 'MLT client received an affiliate reward as first deposit');
        $self->save();

        delete $self->{mlt_affiliate_first_deposit};
    }

    return $trx;
}

#######################################
sub payment_doughflow {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'external_cashier';
    my $staff        = $args{staff}        || 'system';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my %doughflow_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::Doughflow->meta->column($_) }
        keys %args;
    $doughflow_values{transaction_type}  ||= $action_type;
    $doughflow_values{trace_id}          ||= 0;
    $doughflow_values{created_by}        ||= $staff;
    $doughflow_values{payment_processor} ||= 'unspecified';

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'doughflow',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });
    $payment->doughflow(\%doughflow_values);
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;

    if ($action_type eq 'deposit') {
        stats_count('business.usd_deposit.cashier', int(in_USD($amount, $currency) * 100));
        stats_inc('business.cashier');
    }

    return $trx;
}

#######################################
sub payment_free_gift {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'free_gift';
    my $staff        = $args{staff}        || 'system';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'free_gift',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });
    $payment->free_gift({reason => $remark});
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;
    return $trx;
}

#######################################
sub payment_payment_fee {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'payment_fee';
    my $staff        = $args{staff}        || 'system';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'payment_fee',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });
    $payment->payment_fee({});
    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    return $trx;
}

#######################################
sub payment_western_union {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'cash_transfer';
    my $staff        = $args{staff}        || 'system';

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $fdp         = $self->is_first_deposit_pending;
    my $account     = $self->set_default_account($currency);

    my %wu_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::WesternUnion->meta->column($_) }
        keys %args;
    $wu_values{mtcn_number}     ||= '';
    $wu_values{payment_country} ||= '';

    my ($payment) = $account->add_payment({
        amount               => $amount,
        payment_gateway_code => 'western_union',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
    });

    $payment->western_union(\%wu_values);

    my ($trx) = $payment->add_transaction({
        account_id    => $account->id,
        amount        => $amount,
        staff_loginid => $staff,
        referrer_type => 'payment',
        action_type   => $action_type,
        quantity      => 1,
    });
    $account->save(cascade => 1);
    $trx->load;    # to re-read 'now' timestamps

    BOM::Platform::Client::IDAuthentication->new(client => $self)->run_authentication if $fdp;

    return $trx;
}

# Validate Payment Agent transactions
sub validate_agent_payment {
    my ($fmClient, %args) = @_;

    my $toClient = delete $args{toClient} || die "no toClient";
    my $currency = delete $args{currency} || die "no currency";
    my $amount   = delete $args{amount}   || die "no amount";

    # Default: withdraw from PA acc = Deposit to client
    my $payment_agent = $fmClient;
    my $action_type   = 'withdraws';
    my $client        = $toClient;

    # deposit into PA acc = Withdraw from client
    if ($toClient->payment_agent) {
        $payment_agent = $toClient;
        $client        = $fmClient;
        $action_type   = 'deposit';
    }

    my $allow_withdraw = $client->allow_paymentagent_withdrawal();
    if (not $allow_withdraw) {
        die "doughflow payment exist, not allow for payment agent withdrawal";
    }

    # Payments agents are unavailable at the weekend
    if (DateTime->now->day_of_week() > 5) {
        die "payments agents are unavailable at the weekend (UTC timezone)";
    }
    my $today = Date::Utility::today->date;
    # Total transaction for the day
    my $query = [
        payment_gateway_code => 'payment_agent_transfer',
        payment_time         => {gt => $today}];

    my $total = $client->default_account->find_payment(
        query  => $query,
        select => 'sum(amount) as amount'
    );
    my $count = $client->default_account->payment_count($query) || 0;

    my $total_amount = scalar @$total ? $total->[0]->amount || 0 : 0;

    my $payment_agent_transfer_datamapper =
        BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({client_loginid => $payment_agent->loginid});
    my $pa_total_amount = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_total_amount;
    $pa_total_amount = amount_from_to_currency($pa_total_amount + abs($amount), $payment_agent->default_account->currency_code, 'USD');

    if ($pa_total_amount > 100_000) {
        die "Payment agents can not exceed an aggregate value of 100,000 in a day\n";
    }

    my $pa_transaction_count = $payment_agent->default_account->payment_count($query) || 0;
    ## Payment agents can have no more than 1000 transactions per day

    if ($pa_transaction_count >= 1000) {
        die "Payment agents can have no more than 1000 transactions per day. \n";
    }

    ## Rule one
    if ($amount > 2500) {
        die "The maximum amount allowed for this transaction is $currency 2500. \n";
    }

    ## Rule two
    # do not allowed more than 35 transactions per day
    if ($count >= 35) {
        die "You have exceeded the maximum allowable transactions for today. \n";
    }

    ## Rule three
    # limit aggregate of 15,000 per day
    if ($total_amount >= 15000) {
        die "You have exceeded the maximum allowable transfer amount for today.\n";
    }
}

1;


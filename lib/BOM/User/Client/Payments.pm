## no critic (RequireFilenameMatchesPackage)

package BOM::User::Client;

use strict;
use warnings;
use feature qw(state);

use Try::Tiny;
use List::Util;
use YAML::XS qw(LoadFile);
use Path::Tiny;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use Date::Utility;
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use JSON::MaybeXS ();
use Encode;

use BOM::User::Client::PaymentNotificationQueue;
use BOM::User::Client::PaymentTransaction::Doughflow;
use BOM::Database::ClientDB;
use BOM::Config;

## VERSION

# NOTE.. this is a 'mix-in' of extra subs for BOM::User::Client.  It is not a distinct Class.

my $json = JSON::MaybeXS->new;

sub validate_payment {
    my ($self, %args) = @_;
    my $currency = $args{currency} || die "no currency\n";
    my $amount   = $args{amount}   || die "no amount\n";
    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->default_account || die "no account\n";
    my $accbal  = $account->balance;
    my $acccur  = $account->currency_code();
    my $absamt  = abs($amount);

    die "Client\'s cashier is locked.\n"
        if $self->status->cashier_locked;

    die "Client is disabled.\n"
        if $self->status->disabled;

    die "Payment currency [$currency] not client currency [$acccur].\n"
        if $currency ne $acccur;

    if ($action_type eq 'deposit') {
        die "Deposits blocked for this Client.\n"
            if $self->status->unwelcome;

        if (    $self->landing_company->short eq 'malta'
            and $self->is_first_deposit_pending
            and ($args{payment_type} // '') eq 'affiliate_reward')
        {
            $self->{mlt_affiliate_first_deposit} = 1;
        }

        my $max_balance = $self->get_limit({'for' => 'account_balance'});
        die "Balance would exceed $max_balance limit [$currency] [" . $self->loginid . "] \n"
            if ($amount + $accbal) > $max_balance;

        if ($self->landing_company->short eq 'iom') {
            my $max_deposit_limits = $self->get_limits_for_max_deposit();

            # Call get_total_deposit and validate against limits
            if ($max_deposit_limits) {
                my $deposit_over_period = $self->db->dbic->run(
                    ping => sub {
                        my $sth = $_->prepare('SELECT payment.get_total_deposit(?,?,?,?)');
                        $sth->execute(
                            $self->loginid,
                            $max_deposit_limits->{begin},
                            $max_deposit_limits->{end},
                            "{mt5_transfer}"    # exclude mt5 transfers
                        );
                        return $sth->fetchrow_arrayref()->[0];
                    });
                die
                    "Deposit exceeds limit [$max_deposit_limits->{max_deposit}]. Aggregated deposit over period [$deposit_over_period]. Current amount [$amount]."
                    if ($deposit_over_period + $amount) > $max_deposit_limits->{max_deposit};
            }
        }
    }

    if ($action_type eq 'withdrawal') {
        die "Withdrawal is disabled.\n"
            if $self->status->withdrawal_locked;

        die "Missing personal details required for withdrawal.\n"
            if ($self->missing_requirements('withdrawal'));

        die "Withdrawal amount [$currency $absamt] exceeds client balance [$currency $accbal].\n"
            if financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $accbal);

        if (my $frozen = $self->get_withdrawal_limits->{frozen_free_gift}) {
            my $unfrozen = financialrounding('amount', $currency, $accbal - $frozen);
            die sprintf "Withdrawal is [%s %s] but balance [%s] includes frozen bonus [%s].\n", $currency,
                formatnumber('amount', $currency, $absamt), formatnumber('amount', $currency, $accbal), formatnumber('amount', $currency, $frozen)
                if financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $unfrozen);
        }

        return 1 if $self->fully_authenticated;

        my $lc = $self->landing_company->short;
        my $lc_limits;
        my $withdrawal_limits = BOM::Config::payment_limits()->{withdrawal_limits};
        $lc_limits = $withdrawal_limits->{$lc};
        die "Invalid landing company - $lc\n" unless $lc_limits;

        # for CR & CH only check for lifetime limits (in client's currency)
        if ($lc =~ /^(?:svg|champion)$/) {
            # Withdrawals to date
            my $wd_epoch    = $account->total_withdrawals();
            my $lc_currency = $lc_limits->{currency};

            # If currency is not the same as the lc's currency, convert withdrawals so far and withdrawal amount
            if ($currency ne $lc_currency) {
                $wd_epoch = convert_currency($wd_epoch, $currency, $lc_currency) if $wd_epoch > 0;
                $absamt   = convert_currency($absamt,   $currency, $lc_currency) if $absamt > 0;
            }

            # total withdrawal inclusive of this one
            my $total_wd = financialrounding('amount', $currency, $wd_epoch + $absamt);
            my $wd_left  = financialrounding('amount', $currency, $lc_limits->{lifetime_limit} - $wd_epoch);

            if (financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $wd_left)) {
                if ($currency ne $lc_currency) {
                    die sprintf "Withdrawal amount [%s %s] exceeds withdrawal limit [%s %s].\n", $currency,
                        formatnumber('amount', $currency, convert_currency($absamt, $lc_currency, $currency)),
                        $currency, formatnumber('amount', $currency, convert_currency($wd_left, $lc_currency, $currency));
                } else {
                    die sprintf "Withdrawal amount [%s %s] exceeds withdrawal limit [%s %s].\n", $currency,
                        formatnumber('amount', $currency, $absamt),
                        $currency, formatnumber('amount', $currency, $wd_left);
                }
            }

            if ($total_wd >= financialrounding('amount', $currency, $lc_limits->{lifetime_limit})) {
                $self->set_authentication('ID_DOCUMENT')->status('needs_action');
                $self->save();
            }

        } else {
            my $for_days = $lc_limits->{for_days};
            my $since    = Date::Utility->new->minus_time_interval("${for_days}d");

            # Obtains limit in EUR
            my $wd_eur_since_limit = $lc_limits->{limit_for_days};
            my $wd_eur_epoch_limit = $lc_limits->{lifetime_limit};

            my %wd_query = (
                amount               => {lt => 0},
                payment_gateway_code => {ne => 'currency_conversion_transfer'});

            # Obtains payments over the lifetime of the account
            my $wd_epoch = $account->total_withdrawals();

            # Obtains payments over the last x days
            my $wd_since = $account->total_withdrawals($since);

            # Converts payments over lifetime of the account and the last x days into EUR
            my $wd_eur_since = convert_currency($wd_since, $currency, 'EUR');
            my $wd_eur_epoch = convert_currency($wd_epoch, $currency, 'EUR');

            # Amount withdrawable over the last x days in EUR
            my $wd_eur_since_left = $wd_eur_since_limit - $wd_eur_since;

            # Amount withdrawable over the lifetime of the account in EUR
            my $wd_eur_epoch_left = $wd_eur_epoch_limit - $wd_eur_epoch;

            # Withdrawable amount left between the two amounts - The smaller is used
            my $wd_eur_left = List::Util::min($wd_eur_since_left, $wd_eur_epoch_left);

            # Withdrawable amount is converted from EUR to clients' currency and rounded
            my $wd_left = financialrounding('amount', $currency, convert_currency($wd_eur_left, 'EUR', $currency));

            if (financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $wd_left)) {
                # lock cashier and unwelcome if its MX (as per compliance, check with compliance if you want to remove it)
                if ($lc eq 'iom') {
                    $self->status->multi_set_clear({
                        set        => ['cashier_locked', 'unwelcome'],
                        staff_name => 'system',
                        reason     => 'Exceeds withdrawal limit',
                    });
                }
                my $msg = "Withdrawal amount [%s %s] exceeds withdrawal limit [EUR %s]";
                my @values = ($currency, formatnumber('amount', $currency, $absamt), formatnumber('amount', $currency, $wd_eur_left));
                if ($currency ne 'EUR') {
                    $msg = "$msg (equivalent to %s %s)";
                    push @values, $currency, formatnumber('amount', $currency, $wd_left);
                }
                die sprintf "$msg.\n", @values;
            }
        }

    }

    return 1;
}

sub deposit_virtual_funds {
    my ($self, $source, $remark) = @_;
    $self->is_virtual || die "not a virtual client\n";

    my $currency = 'USD';
    my $amount   = 10000;

    my $trx = $self->payment_legacy_payment(
        currency     => $currency,
        amount       => $amount,
        payment_type => 'virtual_credit',
        remark       => $remark // 'Virtual money credit to account',
        source       => $source,
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
        crypto_cashier      => 'legacy_payment',
        test_account        => 'legacy_payment',
        commission_paid     => 'legacy_payment',
        dormant_fee         => 'payment_fee',
        payment_fee         => 'payment_fee',
        bank_money_transfer => 'bank_wire',
        arbitrary_markup    => 'arbitrary_markup',
        cash_transfer       => 'western_union',      # ! need to fix in db first
    );

    $payment_gateway_code ||= $gateway_map{$payment_type}
        || die "unsupported payment_type: $payment_type";
    my $payment_handler = "payment_$payment_gateway_code";
    return $self->$payment_handler(%args);
}

sub payment_legacy_payment {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || die "no payment_type";
    my $staff        = $args{staff}        || 'system';

    # these are only here to support some tests which set up historic payments :(
    my $payment_time     = delete $args{payment_time};
    my $transaction_time = delete $args{transaction_time};
    my $source           = delete $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    die "cannot deal in $currency; clients currency is " . $account->currency_code() if $account->currency_code() ne $currency;

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'legacy_payment',
            payment_type_code    => $payment_type,
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
            ($payment_time     ? (payment_time     => $payment_time)     : ()),
            ($transaction_time ? (transaction_time => $transaction_time) : ()),
        },
        {});    # <- TODO: legacy_payment table is redundant

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'legacy',
        currency      => $currency,
        loginid       => $self->loginid,
        type          => $action_type,
        amount        => $amount,
        payment_agent => $self->payment_agent ? 1 : 0,
    );

    return $trx;
}

sub payment_account_transfer {
    my ($fmClient, %args) = @_;

    my $toClient = delete $args{toClient} || die "no toClient";
    my $currency = delete $args{currency} || die "no currency";
    my $amount   = delete $args{amount}   || die "no amount";
    my $to_amount = delete $args{to_amount};
    # fees can be zero as well
    my $fees = delete $args{fees} // die "no fees";
    my $staff    = delete $args{staff}    || 'system';
    my $toStaff  = delete $args{toStaff}  || $staff;
    my $fmStaff  = delete $args{fmStaff}  || $staff;
    my $remark   = delete $args{remark};
    my $toRemark = delete $args{toRemark} || $remark || ("Transfer from " . $fmClient->loginid);
    my $fmRemark = delete $args{fmRemark} || $remark || ("Transfer to " . $toClient->loginid);
    my $source             = delete $args{source};
    my $is_agent_to_client = delete $args{is_agent_to_client} // 0;
    my $lc_lifetime_limit  = delete $args{lc_lifetime_limit};
    my $lc_for_days        = delete $args{lc_for_days};
    my $lc_limit_for_days  = delete $args{lc_limit_for_days};

    # if client has no default account then error out
    my $fmAccount = $fmClient->default_account || die "Client does not have a default account\n";
    my $toAccount = $toClient->default_account || die "toClient does not have a default account\n";

    my $inter_db_transfer;
    $inter_db_transfer = delete $args{inter_db_transfer} if (exists $args{inter_db_transfer});
    my $gateway_code = delete $args{gateway_code} || 'account_transfer';

    my $from_curr = $fmClient->account->currency_code();
    my $to_curr   = $toClient->account->currency_code();

    if ($to_curr ne $from_curr and not defined $to_amount) {
        die "to_amount is required if from_currency and to_currency are different";
    } elsif ($to_curr eq $from_curr) {
        $to_amount = $amount;
    }

    $to_amount = financialrounding('amount', $to_curr, $to_amount);
    my $dbic = $fmClient->db->dbic;
    unless ($inter_db_transfer) {
        # here we rely on ->set_default_account above
        # which makes sure the `write` database is used.
        my $response;
        my $records = $dbic->run(
            # Error handling for code below is tricky; it returns a string for normal DB  errors,
            # and an array ref for custom DB errors (starts with "BI").
            ping => sub {
                my $sth = $_->prepare('SELECT (v_from_trans).id FROM payment.payment_account_transfer(?,?,?,?,?,?,?, ?,?,?,?,?,?, ?,?,?)');
                $sth->execute(
                    $fmClient->loginid,  $toClient->loginid, $currency,    $amount, $to_amount, $fmStaff,
                    $toStaff,            $fmRemark,          $toRemark,    $source, $fees,      $gateway_code,
                    $is_agent_to_client, $lc_lifetime_limit, $lc_for_days, $lc_limit_for_days
                );
                return $sth->fetchall_arrayref({});
            });
        if (scalar @{$records}) {
            $response->{transaction_id} = $records->[0]->{id};
        }
        return $response;
    }

    # TODO: Interclient transfers ("Transfer Between Accounts") lacks
    #       atomicity and is unsafe; we could potentially debit from one
    #       account and fail to credit into the other. We need to
    #       investigate a safe implementation or drop it altogether.
    my ($fmTrx) = $fmAccount->add_payment_transaction({
        amount               => -$amount,
        payment_gateway_code => $gateway_code,
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $fmStaff,
        remark               => $fmRemark,
        account_id           => $fmAccount->id,
        staff_loginid        => $fmStaff,
        source               => $source,
        transfer_fees        => $fees,
    });

    my ($toTrx) = $toAccount->add_payment_transaction({
        amount               => $to_amount,
        payment_gateway_code => $gateway_code,
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $toStaff,
        remark               => $toRemark,
        account_id           => $toAccount->id,
        staff_loginid        => $toStaff,
        source               => $source,
    });

    return {transaction_id => $fmTrx->transaction_id};
}

sub payment_doughflow {
    # Doughflow payments may charge payment fees in cases where
    # clients deposit, did not trade and want their money back.
    # To ensure the atomicity of both the doughflow payment and its
    # corresponding payment fee, a seperate DB function that makes 2
    # calls to add_payment_transaction is used.
    #
    # add_doughflow_payment returns a superset of add_payment_transaction,
    # adding fee_transaction_id and fee_payment_id, so existing code can
    # expect the same outputs as other payment methods in this file.
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'external_cashier';
    my $staff        = $args{staff}        || 'system';
    my $payment_fee  = $args{payment_fee};
    my $source       = $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my %doughflow_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::Doughflow->meta->column($_) }
        keys %args;
    $doughflow_values{transaction_type}  ||= $action_type;
    $doughflow_values{trace_id}          ||= 0;
    $doughflow_values{created_by}        ||= $staff;
    $doughflow_values{payment_processor} ||= 'unspecified';

    my @bind_params =
        ($account->id, $amount, $payment_type, $staff, $remark, Encode::encode_utf8($json->encode(\%doughflow_values)), $payment_fee,);

    my $trx = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT t.* from payment.add_doughflow_payment(?,?,?,?,?,?,?) t", undef, @bind_params);
        });

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'doughflow',
        currency      => $currency,
        loginid       => $self->loginid,
        type          => $action_type,
        amount        => $amount,
        payment_agent => $self->payment_agent ? 1 : 0,
    );
    return BOM::User::Client::PaymentTransaction::Doughflow->new(%$trx);
}

sub payment_free_gift {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'free_gift';
    my $staff        = $args{staff}        || 'system';
    my $source       = $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'free_gift',
            payment_type_code    => $payment_type,
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
        },
        {reason => $remark});    # <- TODO: This is redundant; we are already storing remark in payments table.

    return $trx;
}

sub payment_mt5_transfer {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'mt5_transfer';
    my $staff        = $args{staff}        || 'system';
    my $fees         = $args{fees};
    my $source       = $args{source};

    my $account = $self->set_default_account($currency);

    my ($trx) = $account->add_payment_transaction({
        amount               => $amount,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
        account_id           => $account->id,
        source               => $source,
        transfer_fees        => $fees,
    });

    return $trx;
}

sub payment_payment_fee {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'payment_fee';
    my $staff        = $args{staff}        || 'system';
    my $source       = $args{source};

    my $account = $self->set_default_account($currency);

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'payment_fee',
            payment_type_code    => $payment_type,
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
        },
        {});    # <- TODO: we currently don't charge payment_fee; this table is redundant.

    return $trx;
}

sub payment_bank_wire {
    my ($self, %args) = @_;

    my $currency = delete $args{currency} || die "no currency";
    my $amount   = delete $args{amount}   || die "no amount";
    my $staff    = delete $args{staff}    || 'system';
    my $remark   = delete $args{remark}   || '';
    my $source   = delete $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my %bank_wire_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::BankWire->meta->column($_) }
        keys %args;

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'bank_wire',
            payment_type_code    => 'bank_money_transfer',
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
        },
        \%bank_wire_values
    );

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'bankwire',
        currency      => $currency,
        loginid       => $self->loginid,
        type          => $action_type,
        amount        => $amount,
        payment_agent => $self->payment_agent ? 1 : 0,
    );

    return $trx;
}

sub payment_affiliate_reward {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'affiliate_reward';
    my $staff        = $args{staff}        || 'system';
    my $source       = $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'affiliate_reward',
            payment_type_code    => $payment_type,
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
        },
        {});    # <- TODO: affiliate_reward table is redundant

    if (exists $self->{mlt_affiliate_first_deposit} and $self->{mlt_affiliate_first_deposit}) {
        $self->status->set('cashier_locked', 'system', 'MLT client received an affiliate reward as first deposit');

        delete $self->{mlt_affiliate_first_deposit};
    }

    return $trx;
}

sub payment_western_union {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'cash_transfer';
    my $staff        = $args{staff}        || 'system';
    my $source       = $args{source};

    my $action_type = $amount > 0 ? 'deposit' : 'withdrawal';
    my $account = $self->set_default_account($currency);

    my %wu_values = map { $_ => $args{$_} }
        grep { BOM::Database::AutoGenerated::Rose::WesternUnion->meta->column($_) }
        keys %args;
    $wu_values{mtcn_number}     ||= '';
    $wu_values{payment_country} ||= '';

    my ($trx) = $account->add_payment_transaction({
            amount               => $amount,
            payment_gateway_code => 'western_union',
            payment_type_code    => $payment_type,
            status               => 'OK',
            staff_loginid        => $staff,
            remark               => $remark,
            account_id           => $account->id,
            source               => $source,
        },
        \%wu_values
    );

    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'westernunion',
        currency      => $currency,
        loginid       => $self->loginid,
        type          => $action_type,
        amount        => $amount,
        payment_agent => $self->payment_agent ? 1 : 0,
    );

    return $trx;
}

sub payment_arbitrary_markup {
    my ($self, %args) = @_;

    my $currency     = $args{currency}     || die "no currency";
    my $amount       = $args{amount}       || die "no amount";
    my $remark       = $args{remark}       || die "no remark";
    my $payment_type = $args{payment_type} || 'arbitrary_markup';
    my $staff        = $args{staff}        || 'system';
    my $source       = $args{source};

    my $account = $self->set_default_account($currency);

    my ($trx) = $account->add_payment_transaction({
        amount               => $amount,
        payment_gateway_code => 'arbitrary_markup',
        payment_type_code    => $payment_type,
        status               => 'OK',
        staff_loginid        => $staff,
        remark               => $remark,
        account_id           => $account->id,
        source               => $source,
    });

    return $trx;
}

1;


package BOM::Rules::RuleRepository::Payment;

=head1 NAME

BOM::Rules::RuleRepository::Payment

=head1 DESCRIPTION

Contains rules pertaining client's payments.

=cut

use strict;
use warnings;

use Format::Util::Numbers            qw(roundcommon financialrounding formatnumber);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use List::Util                       qw(min max any sum);

use Business::Config::LandingCompany;

use Business::Config::LandingCompany;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;

rule 'payment.currency_matches_account' => {
    description => "It fails if the payment currency is different from client's account currency.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $currency         = $args->{currency} or die 'Payment currency is missing';
        my $account_currency = $context->client($args)->account->currency_code // '';

        $self->fail('CurrencyMismatch', params => [$currency, $account_currency]) unless $account_currency eq $currency;

        return 1;
    },
};

rule 'deposit.total_balance_limits' => {
    description => "It fails if client's balance exceeds the limit with current deposit amount.",
    code        => sub {
        my ($self, $context, $args) = @_;

        die "The rule $self->{name} is for deposit actions only" unless ($args->{action} // '') eq 'deposit';

        my $client   = $context->client($args);
        my $amount   = $args->{amount} // die 'Amount is required';
        my $currency = $client->account->currency_code;

        # max balance can be unlimited
        return 1 if $client->landing_company->unlimited_balance;

        my $max_balance = $client->get_limit({'for' => 'account_balance'});

        return 1 unless ($amount + $client->account->balance) > $max_balance;

        if (    $client->get_self_exclusion
            and defined $client->get_self_exclusion->max_balance
            and $client->get_self_exclusion->max_balance < $client->fixed_max_balance // 0)
        {
            $self->fail('SelfExclusionLimitExceeded', params => [$max_balance, $currency]);
        }

        $self->fail('BalanceExceeded', params => [$max_balance, $currency]);
    },
};

rule 'deposit.periodical_balance_limits' => {
    description => "Checks the amount to be deposited against client's daily, weekly, and monthly deposit limits.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $amount = $args->{amount} // die 'Amount is required';
        die "The rule $self->{name} is for deposit actions only" unless ($args->{action} // '') eq 'deposit';

        my $client = $context->client($args);
        return 1 unless $client->landing_company->deposit_limit_enabled;

        my $deposit_limits = $client->get_deposit_limits();

        my %limit_days_to_name = (
            1  => 'daily',
            7  => '7day',
            30 => '30day',
        );

        my $period_end = Date::Utility->new;

        for my $limit_days (sort { $a <=> $b } keys %limit_days_to_name) {
            my $limit_name   = $limit_days_to_name{$limit_days};
            my $limit_amount = $deposit_limits->{$limit_name};

            next unless defined $limit_amount;

            # Call get_total_deposit and validate against limits
            my $period_start = $period_end->minus_time_interval("${limit_days}d");

            my ($deposit_over_period) = $client->db->dbic->run(
                fixup => sub {
                    return $_->selectrow_array('SELECT payment.get_total_deposit(?,?,?,?)',
                        undef, $client->loginid, $period_start->datetime, $period_end->datetime, '{mt5_transfer}');
                }) // 0;

            $self->fail("DepositLimitExceeded", params => [$limit_name, $limit_amount, $deposit_over_period, $amount])
                if ($deposit_over_period + $amount) > $limit_amount;
        }

        return 1;
    },
};

rule 'withdrawal.age_verification_limits' => {
    description => "Checks the crypto amount to be withdrawn is not greater than the limit set",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $amount       = $args->{amount}       // die 'Amount is required';
        my $payment_type = $args->{payment_type} // return 1;
        my $action       = $args->{action};
        my ($withdrawal_over_period, $USD_amount);
        my $limit_amount = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->crypto_to_crypto;
        return unless $payment_type eq 'crypto_cashier';
        return unless $limit_amount > 0;
        my $client         = $context->client($args);
        my $from_currency  = $client->currency;
        my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
        $withdrawal_over_period = $payment_mapper->get_total_withdrawal({
            exclude => ['account_transfer'],
        });
        $withdrawal_over_period = convert_currency($withdrawal_over_period, $from_currency, 'USD') if $from_currency ne 'USD';
        $USD_amount             = convert_currency($amount,                 $from_currency, 'USD') if $from_currency ne 'USD';
        $self->fail("CryptoLimitAgeVerified", params => [abs($amount), $from_currency, $limit_amount])
            if (abs($withdrawal_over_period) + abs($USD_amount)) > $limit_amount && !$client->status->age_verification;
    }
};

rule 'withdrawal.less_than_balance' => {
    description => "It check if withdrawal amount is less than client's balance; it fails otherwise.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        my $amount = $args->{amount} // die 'Amount is required';
        die "The rule $self->{name} is for withdrawal actions only" unless ($args->{action} // '') eq 'withdrawal';

        my $absamt   = abs($amount);
        my $currency = $client->account->currency_code;
        my $balance  = $client->account->balance;

        my $formatted_accbal = formatnumber('amount', $currency, $balance);
        $self->fail('AmountExceedsBalance', params => [$absamt, $currency, $formatted_accbal])
            if financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $balance);

        return 1;
    },
};

rule 'withdrawal.only_unfrozen_balance' => {
    description => "It checks if withdrawal amount is less than unfrozen balance; we cannot withdraw from frozen amounts.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        my $amount = $args->{amount} // die 'Amount is required';
        die "The rule $self->{name} is for withdrawal actions only" unless ($args->{action} // '') eq 'withdrawal';

        my $absamt   = abs($amount);
        my $currency = $client->account->currency_code;
        my $balance  = $client->account->balance;

        return 1 unless $args->{action} eq 'withdrawal';

        my $formatted_accbal = formatnumber('amount', $currency, $balance);
        if (my $frozen = $client->get_withdrawal_limits->{frozen_free_gift}) {
            my $unfrozen = financialrounding('amount', $currency, $balance - $frozen);
            $self->fail(
                'AmountExceedsUnfrozenBalance',
                params => [$currency, formatnumber('amount', $currency, $absamt), $formatted_accbal, formatnumber('amount', $currency, $frozen)],
            ) if financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $unfrozen);
        }

        return 1;
    },
};

rule 'withdrawal.landing_company_limits' => {
    description =>
        "Checks withdrawal limits lifetime and periodical limits defined in payment_limits.yml (authenticated clients and internal transfers are exempted)",
    code => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);
        my $amount = $args->{amount} // die 'Amount is required';
        die "The rule $self->{name} is for withdrawal actions only" unless ($args->{action} // '') eq 'withdrawal';

        return 1 if $client->fully_authenticated;
        return 1 if $args->{is_internal};

        my $lc                = $context->landing_company_object($args);
        my $withdrawal_limits = Business::Config::LandingCompany->new()->payment_limit()->{withdrawal_limits};
        my $lc_limits         = $withdrawal_limits->{$lc->short} or $self->fail("InvalidLandingCompany", params => [$lc->short]);
        my $lc_currency       = $lc_limits->{currency};
        my $account           = $client->account;
        my $currency          = $account->currency_code;
        my $absamt            = abs($amount);

        # Withdrawals to date
        my $wd_epoch = $account->total_withdrawals();
        my $total_wd = financialrounding('amount', $currency, $wd_epoch + $absamt);

        if ($lc->lifetime_withdrawal_limit_check) {
            # If currency is not the same as the lc's currency, convert withdrawals so far and withdrawal amount
            if ($currency ne $lc_currency) {
                $wd_epoch = convert_currency($wd_epoch, $currency, $lc_currency) if $wd_epoch > 0;
                $absamt   = convert_currency($absamt,   $currency, $lc_currency) if $absamt > 0;
            }

            my $wd_left = financialrounding('amount', $currency, $lc_limits->{lifetime_limit} - $wd_epoch);
            $self->fail('WithdrawalLimitReached', params => [financialrounding('amount', $lc_currency, $lc_limits->{lifetime_limit}), $lc_currency])
                if $wd_left <= 0;

            if (financialrounding('amount', $currency, $absamt) > financialrounding('amount', $currency, $wd_left)) {
                if ($currency ne $lc_currency) {
                    $self->fail('WithdrawalLimit', params => [convert_currency($wd_left, $lc_currency, $currency), $currency]);
                } else {
                    $self->fail('WithdrawalLimit', params => [$wd_left, $currency]);
                }
            }

        } else {
            my $for_days = $lc_limits->{for_days};
            my $since    = Date::Utility->new->minus_time_interval("${for_days}d");

            # Obtains limit
            my $wd_since_limit = financialrounding('amount', $lc_currency, $lc_limits->{limit_for_days});
            my $wd_epoch_limit = financialrounding('amount', $lc_currency, $lc_limits->{lifetime_limit});

            # Obtains payments over the last x days
            my $wd_since = $account->total_withdrawals($since);

            # Converts payments over lifetime of the account and the last x days
            my $wd_since_converted = convert_currency($wd_since, $currency, $lc_currency);
            my $wd_epoch_converted = convert_currency($wd_epoch, $currency, $lc_currency);

            # Amount withdrawable over the last x days
            my $wd_since_left = financialrounding('amount', $currency, $wd_since_limit - $wd_since_converted);
            $self->fail('WithdrawalLimitReached', params => [$wd_since_limit, $lc_currency]) if $wd_since_left <= 0;

            # Amount withdrawable over the lifetime of the account
            my $wd_epoch_left = financialrounding('amount', $currency, $wd_epoch_limit - $wd_epoch_converted);
            $self->fail('WithdrawalLimitReached', params => [$wd_epoch_limit, $lc_currency]) if $wd_epoch_left <= 0;

            # Withdrawable amount left between the two amounts - The smaller is used
            my $wd_left_min = min($wd_since_left, $wd_epoch_left);

            # Withdrawable amount is converted from the limit config currency to clients' currency and rounded
            my $wd_left = financialrounding('amount', $currency, convert_currency($wd_left_min, $lc_currency, $currency));

            if (financialrounding('amount', $currency, $absamt) > $wd_left) {
                # lock cashier and unwelcome if its MX (as per compliance, check with compliance if you want to remove it)
                if ($lc->short eq 'iom') {
                    # TODO: we've got to find an elegant way to move this block out of rule engine.
                    $client->status->multi_set_clear({
                        set        => ['cashier_locked', 'unwelcome'],
                        staff_name => 'system',
                        reason     => 'Exceeds withdrawal limit',
                    });
                }
                $self->fail('WithdrawalLimit', params => [$wd_left, $currency]);
            }
        }

        # TODO: another side-effect. It should be moved out of rule engine.
        if ($total_wd >= financialrounding('amount', $currency, $lc_limits->{lifetime_limit})) {
            BOM::Platform::Event::Emitter::emit('withdrawal_limit_reached', {loginid => $client->loginid});
        }

        return 1;
    },
};

rule 'withdrawal.p2p_and_payment_agent_deposits' => {
    description => "Prevents net P2P and PA deposits from being withdrawn via external cashiers.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $payment_type    = $args->{payment_type};
        my $client          = $context->client($args);
        my $client_balance  = $client->account->balance;
        my $client_currency = $client->currency;
        my $excluded_p2p    = 0;
        my $excluded_pa     = 0;

        # P2P excluded balance
        # For now we prevent internal transfers of p2p to block the route of crypto withdrawal
        if (any { $payment_type eq $_ } qw(internal_transfer doughflow paymentagent_withdraw)) {
            my $pa = $client->payment_agent;

            # A PA can only use P2P + cashier if they have been given both rights by compliance so we won't block them here.
            unless ($pa && ($pa->status // '') eq 'authorized') {
                $excluded_p2p = $client_balance - $client->p2p_withdrawable_balance;
            }
        }

        # PA excluded balance
        if (any { $payment_type eq $_ } qw(doughflow crypto_cashier)) {
            my $lookback = BOM::Config::Runtime->instance->app_config->payments->payment_agent_deposits_lookback;

            if ($lookback > 0) {
                my $accounts = $client->db->dbic->run(
                    fixup => sub {
                        return $_->selectall_arrayref(
                            'SELECT * FROM payment.payment_agent_deposit_totals(?,?)',
                            {Slice => {}},
                            $client->user->id, $lookback
                        );
                    });

                # the limit is calculated from all siblings, since internal transfers are not restricted
                my $total_net_pa_deposits = sum(map { convert_currency($_->{net_deposits}, $_->{currency}, $client_currency) } @$accounts) // 0;

                if ($total_net_pa_deposits > 0) {
                    my $total_balance = sum(map { convert_currency($_->{balance}, $_->{currency}, $client_currency) } @$accounts);
                    my $total_limit   = max(0, $total_balance - $total_net_pa_deposits);
                    $excluded_pa = $client_balance - $total_limit if $total_limit < $client_balance;
                }
            }
        }

        return 1 unless $excluded_p2p > 0 || $excluded_pa > 0;

        my $wd_limit = max(0, $client_balance - ($excluded_p2p + $excluded_pa));
        $wd_limit = financialrounding('amount', $client_currency, $wd_limit);

        if (financialrounding('amount', $client_currency, abs($args->{amount})) > $wd_limit) {
            if ($excluded_p2p > 0 && $excluded_pa > 0) {
                if ($wd_limit == 0) {
                    $self->fail('PAP2PDepositsWithdrawalZero');
                } else {
                    $self->fail('PAP2PDepositsWithdrawalLimit', params => [$wd_limit, $client_currency]);
                }
            } elsif ($excluded_p2p > 0) {
                if ($wd_limit == 0) {
                    $self->fail($payment_type eq 'internal_transfer' ? 'P2PDepositsTransferZero' : 'P2PDepositsWithdrawalZero');
                } else {
                    $self->fail($payment_type eq 'internal_transfer' ? 'P2PDepositsTransfer' : 'P2PDepositsWithdrawal',
                        params => [$wd_limit, $client_currency]);
                }
            } elsif ($excluded_pa > 0) {
                if ($wd_limit == 0) {
                    $self->fail('PADepositsWithdrawalZero');
                } else {
                    $self->fail('PADepositsWithdrawalLimit', params => [$wd_limit, $client_currency]);
                }
            }
        }
    },
};

1;

package BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

use strict;
use warnings;

=head1 NAME

BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve

=head1 DESCRIPTION

Approves crypto payouts that are relatively risk free. It does not reject anything.

Approval is made by considering the following set of rules:

1. Do not approve if the exchange rate is missing for the currency
Tag: EMPTY_AMOUNT_NO_EXCHANGE_RATES

2. Approve if the user has no payment in the last six months.
Tag: NO_RECENT_PAYMENT

3. Do not approve if the payout amount is greater than the configurable allowed limit.
   Do not approve if the payout amount is greater than configurable amount limit allowed per day inclusive of currently Locked withdrawals.
Tag: AMOUNT_ABOVE_THRESHOLD

4. Do not approve if the client has been set with any of the following status:
- cashier_locked,
- disabled,
- no_withdrawal_or_trading,
- withdrawal_locked,
- duplicate_account,
- closed
- unwelcome
Tag: CLIENT_STATUS_RESTRICTED

5. Approve if net deposit ((deposit - withdraw) / deposit) * 100 < acceptable risk (configurable)
Tag: ACCEPTABLE_NET_DEPOSIT

6. Do not approve if the risk percentage is greather than a configurable acceptable risk
Tag: RISK_ABOVE_ACCEPTABLE_LIMIT

6. no auto-approval if the most deposited method not from the same cryptocurrency in last six months (time period is configurable)
Tag: NO_CRYPTOCURRENCY_DEPOSIT

=cut

use DataDog::DogStatsd::Helper qw/stats_inc stats_count/;
use LandingCompany::Registry;
use List::Util   qw(first any max);
use Log::Any     qw($log);
use Scalar::Util qw/blessed/;
use Syntax::Keyword::Try;
use Text::CSV  qw (csv);
use Text::Trim qw(trim);
use Time::Moment;
use URI;
use JSON::MaybeXS;
use Date::Utility;
use BOM::User;

use parent qw(BOM::Platform::CryptoCashier::AutoUpdatePayouts);

use constant TIME_RANGE => 6 * 30 * 86400;    # roughly 6 months in seconds

use constant RESTRICTED_CLIENT_STATUS => {
    cashier_locked           => 1,
    disabled                 => 1,
    no_withdrawal_or_trading => 1,
    withdrawal_locked        => 1,
    duplicate_account        => 1,
    closed                   => 1,
    unwelcome                => 1
};

use constant ACCEPTABLE_PERCENTAGE    => 20;
use constant THRESHOLD_AMOUNT         => 999;
use constant ALLOWED_ABOVE_THRESHOLD  => 0;
use constant THRESHOLD_AMOUNT_PER_DAY => 7999;

=head2 new

Constructor

=over 4

=item * C<broker_code> broker code

=item * C<acceptable_percentage> percentage limit for payouts to be considered to risky to auto-approve, defaults to 20

=item * C<threshold_amount> the upper limit in USD for the total amount that has been withdrawn in the configured time span in the past, payouts after this amount won't be auto-approved

=item * C<threshold_amount_per_day> the upper limit in USD for the total amount that has been withdrawn in current day inclusive of currently LOCKED withdrawals, payouts after this amount won't be auto-approve

=item * C<allowed_above_threshold> boolean flag to remove upper limit for the total amount that has been withdrawn in the configured time span

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{$_} = $args{$_} for keys %args;
    return $self;
}

=head2 run

Entry point to auto approve crypto payouts

Takes the following arguments as named parameters

=over 4

=item * C<is_dry_run> boolean flag to enable actual approval of payouts, if true, no changes will be performed

=item * C<excluded_currencies> [OPTIONAL] comma separated currency_code(s) to exclude specific currencies from auto-approval

=back

=cut

sub run {
    my ($self, %args) = @_;

    try {

        my ($locked_withdrawals) = $self->db_load_locked_crypto_withdrawals($args{excluded_currencies} // '');
        my $withdrawals_today = $self->get_withdrawals_today_per_user();

        $log->debugf('Withdrawals in locked state %s', $locked_withdrawals);

        return undef unless scalar(@$locked_withdrawals);

        my @user_withdraw_pairs = $self->process_locked_withdrawals(
            locked_withdrawals => $locked_withdrawals,
            withdrawals_today  => $withdrawals_today,
            is_dry_run         => $args{is_dry_run},
        );

        my $csv_file_name = $self->csv_export(\@user_withdraw_pairs);

        $self->send_email(attachment => [$csv_file_name]);
    } catch ($e) {
        stats_inc('crypto.payments.autoapprove.failure');
        $log->errorf('Error is %s', $e);
        die $e;
    };

    return undef;
}

=head2 csv_export

Exports to a csv file a combination of user and withdrawal details

Takes as argument a list of hashref of user and withdrawal pairs

    ({
        user => { ... },
        withdrawal => { ... }
    }, {
        ...
    })

The CSV contains the following fields:

- User ID
- Login ID
- Currency
- Amount
- Amount requested (in USD)
- Total amount requested (in USD)
- Total amount requested today (in USD)
- Last reversible deposit date
- Last reversible deposit amount
- Last reversible deposit amount (in USD)
- Last reversible deposit currency
- Reversible deposit (in USD)
- Reversible withdrawal (in USD)
- Risk percentage
- Auto approve
- Tag
- Status

=cut

sub csv_export {
    my ($self)      = shift;
    my @data        = shift->@*;
    my @csv_headers = (
        "User ID",
        "Login ID",
        "Currency",
        "Amount",
        "Amount requested (in USD)",
        "Total amount requested (in USD)",
        "Total amount requested today (in USD)",
        "Last reversible deposit date",
        "Last reversible deposit currency",
        "Reversible deposit (in USD)",
        "Reversible withdrawal (in USD)",
        "Risk percentage",
        "Auto approve",
        "Tag",
        "Status"
    );

    my @csv_rows = ();
    for my $pair (@data) {
        my $user_details       = $pair->{user_details};
        my $withdrawal_details = $pair->{withdrawal_details};

        push @csv_rows,
            [
            $withdrawal_details->{binary_user_id},                 $withdrawal_details->{client_loginid},
            $withdrawal_details->{currency_code},                  $withdrawal_details->{amount},
            $withdrawal_details->{amount_in_usd},                  $withdrawal_details->{total_withdrawal_amount_in_usd},
            $user_details->{total_withdrawal_amount_today_in_usd}, $user_details->{last_reversible_deposit_date},
            $user_details->{last_reversible_deposit_currency},     $user_details->{reversible_deposit_amount},
            $user_details->{reversible_withdraw_amount},           $user_details->{risk_percentage},
            $user_details->{auto_approve},                         $user_details->{tag},
            $user_details->{restricted_status},
            ];
    }

    mkdir 'autoapproval';
    my $csv_file_name = "autoapproval/crypto_auto_approval_" . Time::Moment->now->strftime('%Y_%m_%d_%H_%M_%S') . ".csv";
    csv(
        in      => \@csv_rows,
        headers => \@csv_headers,
        out     => $csv_file_name,
    );

    return $csv_file_name;
}

=head2 user_activity

Perform and collects details related to user activity on platform

Example usage:
    user_activity(binary_user_id => 1, total_withdrawal_amount => 100, ..)

Takes the following arguments as named parameters

=over 4

=item * C<binary_user_id> - user unique identifier from database

=item * C<total_withdrawal_amount> - total withdrawal amount requested by user

=back

Returns a hash ref with the following keys:

=over 4

=item * C<tag> - String to denote the action taken, possible values are 'EMPTY_AMOUNT_NO_EXCHANGE_RATES', 'CLIENT_STATUS_RESTRICTED', 'NO_RECENT_PAYMENT', 'AMOUNT_ABOVE_THRESHOLD', 'ACCEPTABLE_NET_DEPOSIT', ''RISK_ABOVE_ACCEPTABLE_LIMIT'.

=item * C<auto_approve> - Boolean flag to represent whether to auto approve the payout or not

=item * C<risk_percentage> - risk percentage calculation based on net deposit

=back

=cut

sub user_activity {
    my ($self, %args) = @_;

    my $allowed_above_threshold       = $self->{allowed_above_threshold}  // ALLOWED_ABOVE_THRESHOLD;
    my $threshold_amount              = $self->{threshold_amount}         // THRESHOLD_AMOUNT;
    my $threshold_amount_per_day      = $self->{threshold_amount_per_day} // THRESHOLD_AMOUNT_PER_DAY;
    my $acceptable_percentage         = $self->{acceptable_percentage}    // ACCEPTABLE_PERCENTAGE;
    my $total_withdrawal_amount       = $args{total_withdrawal_amount};
    my $total_withdrawal_amount_today = $args{total_withdrawal_amount_today} // 0;
    my $withdrawal_amount_in_crypto   = $args{withdrawal_amount_in_crypto}   // 0;
    my $currency_code                 = $args{currency_code};
    my $binary_user_id                = $args{binary_user_id};
    my $client_loginid                = $args{client_loginid};
    my $response                      = {};
    # my $user                          = BOM::User->new(id => $binary_user_id);
    $response->{total_withdrawal_amount_today_in_usd} = $total_withdrawal_amount_today;

    my $client_balance = $self->get_client_balance($client_loginid);
    if ($client_balance < $withdrawal_amount_in_crypto) {
        $log->debugf('Client balance %s is lower than the withdrawal amount %s', $client_balance, $withdrawal_amount_in_crypto);
        $response->{tag}          = 'INSUFFICIENT_BALANCE';
        $response->{auto_approve} = 0;
        return $response;
    }

    if ($self->is_client_auto_approval_disabled($client_loginid)) {
        $log->debugf('Auto approval is not enabled for client %s', $client_loginid);
        $response->{tag}          = 'AUTO_APPROVAL_IS_DISABLED_FOR_CLIENT';
        $response->{auto_approve} = 0;
        return $response;
    }

    if (!$total_withdrawal_amount) {
        $response->{tag}          = 'EMPTY_AMOUNT_NO_EXCHANGE_RATES';
        $response->{auto_approve} = 0;
        return $response;
    }
    if (not $allowed_above_threshold and ($threshold_amount < $total_withdrawal_amount || $threshold_amount_per_day < $total_withdrawal_amount_today))
    {
        $response->{tag}          = 'AMOUNT_ABOVE_THRESHOLD';
        $response->{auto_approve} = 0;
        return $response;
    }

    if (my $restricted_status = $self->user_restricted(binary_user_id => $args{binary_user_id})) {
        $response->{tag}               = 'CLIENT_STATUS_RESTRICTED';
        $response->{auto_approve}      = 0;
        $response->{restricted_status} = $restricted_status->{status_code};
        return $response;
    }

    my $start_date_to_inspect = Time::Moment->from_epoch(Time::Moment->now->epoch - TIME_RANGE);
    my ($user_payments) = $self->user_payment_details(
        binary_user_id => $binary_user_id,
        from_date      => $start_date_to_inspect->to_string,
    );
    # TO-DO temporary disabled this check. To be fixed in separate card.
    # my $total_user_deposit_amount = $user_payments->{non_crypto_deposit_amount} + $user_payments->{total_crypto_deposits};
    # my $total_trade_volume        = $user->total_trades($start_date_to_inspect);
    # if ($total_trade_volume < $total_user_deposit_amount / 4) {
    #     $response->{tag}          = 'LOW_TRADE';
    #     $response->{auto_approve} = 0;
    #     return $response;
    # }

    if (!$user_payments->{count}) {
        $log->debugf('User has no payments since %s', $start_date_to_inspect->to_string);
        $response->{tag}          = 'NO_RECENT_PAYMENT';
        $response->{auto_approve} = 1;
        return $response;
    }
    my $all_crypto_net_deposits   = $user_payments->{currency_wise_crypto_net_deposits} // {};
    my $net_crypto_deposit_amount = $all_crypto_net_deposits->{$currency_code}          // 0;
    my $highest_deposited_amount  = $self->find_highest_deposit($user_payments);

    if (%$highest_deposited_amount and $net_crypto_deposit_amount < $highest_deposited_amount->{net_amount_in_usd}) {

        $log->debugf('User has more Fiat deposits than crypto deposits since %s', $start_date_to_inspect->to_string);
        $response->{tag}          = 'NO_CRYPTOCURRENCY_DEPOSIT';
        $response->{auto_approve} = 0;
        return $response;
    }

    $log->debugf('Total user payment records %s', $user_payments);

    my $risk_deposit_amount    = $user_payments->{non_crypto_deposit_amount};
    my $risk_withdrawal_amount = $user_payments->{non_crypto_withdraw_amount};

    if ($user_payments->{has_reversible_payment}) {
        my $last_reversible_deposit = $user_payments->{last_reversible_deposit};
        $log->debugf('User last deposit %s', $last_reversible_deposit);

        $response->{last_reversible_deposit_date}     = $last_reversible_deposit->{payment_time};
        $response->{last_reversible_deposit_currency} = $last_reversible_deposit->{currency_code};
        $response->{reversible_deposit_amount}        = $user_payments->{reversible_deposit_amount};
        $response->{reversible_withdraw_amount}       = $user_payments->{reversible_withdraw_amount};

        $risk_deposit_amount    = $user_payments->{reversible_deposit_amount};
        $risk_withdrawal_amount = $user_payments->{reversible_withdraw_amount};
    }

    my $risk_details = $self->risk_calculation(
        deposit               => $risk_deposit_amount,
        withdraw              => $risk_withdrawal_amount,
        acceptable_percentage => $acceptable_percentage
    );

    $response->{risk_percentage} = $risk_details->{risk_percentage};

    if ($risk_details->{is_acceptable}) {
        $response->{tag}          = 'ACCEPTABLE_NET_DEPOSIT';
        $response->{auto_approve} = 1;
    } else {
        $response->{tag}          = 'RISK_ABOVE_ACCEPTABLE_LIMIT';
        $response->{auto_approve} = 0;
    }

    return $response;
}

=head2 db_approve_withdrawal

Perfom database changes to approve the crypto withdrawal

Takes the following arguments as named parameters

=over 4

=item * C<id> - row id for payment record

=back

=cut

sub db_approve_withdrawal {
    my ($self, %args) = @_;

    my $crypto_api = BOM::Platform::CryptoCashier::InternalAPI->new;
    $crypto_api->verify_withdrawal([{id => $args{id}, currency_code => $args{currency_code}}]);
}

=head2 auto_update_withdrawal

Approve the crypto payout record

Takes the following arguments as named parameters

=over 4

=item * C<withdrawal_details> - see C<db_load_locked_crypto_withdrawals>'s response

=item * C<is_dry_run> - boolean flag to enable actual approval of payouts, if true, will be a dry run and no changes will be performed

=item * C<user_details> - contains data returned by C<user_activity>. the return values differ from case to case.

=back

=cut

sub auto_update_withdrawal {
    my ($self, %args) = @_;

    my $withdrawal_details = $args{withdrawal_details};
    my $is_dry_run         = $args{is_dry_run};
    my $user_details       = $args{user_details};
    my $threshold_amount   = $self->{threshold_amount} // THRESHOLD_AMOUNT;

    if ($is_dry_run) {
        $log->debug('Approvals are not enabled (dry_run=1). It will not approve any withdrawals.');
        return;
    }

    if ($user_details->{auto_approve}) {
        $log->debugf('Approving withdrawal. Details - currency: %s, paymentID: %s.', $withdrawal_details->{currency_code}, $withdrawal_details->{id});

        if (!$withdrawal_details->{amount_in_usd}) {
            # this is not supposed to ever happen
            die $log->errorf(
                'The crypto autoapproval script tried to process an withdrawal with no exchange rates. Please raise it with the back-end team.');
        }

        if (($withdrawal_details->{amount_in_usd}) > $threshold_amount) {
            stats_inc('crypto.payments.autoapprove.amount_over_threshold',
                {tags => ['reason:amount_over_threshold', 'currency:' . $withdrawal_details->{currency_code}]});
            die $log->errorf(
                'The crypto autoapproval script tried processing amount %s above than current threshhold %s. Please raise it with back-end team.',
                $withdrawal_details->{amount_in_usd},
                $threshold_amount
            );
        }

        $self->db_approve_withdrawal(
            id            => $withdrawal_details->{id},
            currency_code => $withdrawal_details->{currency_code});

        stats_inc('crypto.payments.autoapprove.approved',
            {tags => ['reason:' . $user_details->{tag}, 'currency:' . $withdrawal_details->{currency_code}]});
        stats_count(
            'crypto.payments.autoapprove.total_in_usd',
            $withdrawal_details->{amount_in_usd},
            {tags => ['currency:' . $withdrawal_details->{currency_code}]});
    } else {
        stats_inc('crypto.payments.autoapprove.non_approved',
            {tags => ['reason:' . $user_details->{tag}, 'currency:' . $withdrawal_details->{currency_code}]});
    }

    return undef;
}

=head2 is_client_auto_approval_disabled

check if approval is disabled for current client

=over 4

=item * C<binary_user_id> - Client login id

=back

=cut

sub is_client_auto_approval_disabled {

    my ($self, $client_loginid) = @_;

    my $statuses = $self->client_status(client_loginid => $client_loginid);

    return 1 if any { $_->{status_code} eq 'crypto_auto_approve_disabled' } @$statuses;

    return 0;
}

1;

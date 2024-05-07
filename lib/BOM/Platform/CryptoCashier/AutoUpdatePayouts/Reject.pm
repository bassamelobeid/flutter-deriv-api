package BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;

use strict;
use warnings;

=head1 NAME

BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;

=head1 DESCRIPTION

This script aims to automatically reject cryptocurrency withdrawal requests for the following rules defined by payments:

1. Reject cryptocurrency withdrawal requests if the highest net deposit method is not `crypto` within the limit of six months (limit is configurable via BO).
Tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO

=cut

use BOM::Platform::Event::Emitter;
use DataDog::DogStatsd::Helper qw/stats_inc stats_count/;
use List::Util                 qw(any);
use Log::Any                   qw($log);
use Syntax::Keyword::Try;
use Time::Moment;
use Text::CSV qw (csv);
use BOM::User;

use parent qw(BOM::Platform::CryptoCashier::AutoUpdatePayouts);

use constant TIME_RANGE => 6 * 30 * 86400;    # roughly 6 months in seconds

# Rejection reasons to be shown in backoffice and can be used to send client email
use constant {
    REJECTION_REASONS => {
        highest_deposit_method_is_not_crypto => {
            reason => "highest deposit method is not crypto. Request payout via highest deposited method %s",
            remark => "Crypto net deposits are lower compared to other deposit methods. Initiate withdrawal request via most deposited method"
        },
        insufficient_balance => {
            reason => "client does not have sufficient balance",
            remark => "Insufficient balance",
        },
        low_trade => {
            reason => "Total trade amount less than 25 percent of total deposit amount",
            remark => "Low trade, ask client for justification and to request a new payout"
        },
        withdraw_via_ewallet => {
            reason => "highest deposit method is not crypto. Request payout via highest deposited method %s",
            remark => "request a payout via e-wallet",
        },
    },
    TAGS => {
        no_non_crypto_deposits                  => 'NO_NON_CRYPTO_DEPOSITS_RECENTLY',
        highest_deposit_not_crypto              => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
        high_crypto_deposit                     => 'HIGH_CRYPTOCURRENCY_DEPOSIT',
        auto_reject_disable_for_client          => 'AUTO_REJECT_IS_DISABLED_FOR_CLIENT',
        crypto_non_crypto_net_deposits_negative => 'CRYPTO_NON_CRYPTO_NET_DEPOSITS_NEGATIVE',
        insufficient_balance                    => 'INSUFFICIENT_BALANCE',
        withdraw_via_ewallet                    => 'WITHDRAW_VIA_EWALLET',
        low_trade                               => 'LOW_TRADE',
    }};

=head2 new

Constructor

=over 4

=item * C<broker_code> broker code

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{$_} = $args{$_} for keys %args;
    return $self;
}

=head2 run

Entry point to auto reject crypto payouts.

This sub gets all the withdrawals in locked status and sends it for processing.

Takes the following arguments as named parameters

=over 4

=item * C<is_dry_run> boolean flag to dry run, if true, will be a dry run and  no changes will be performed in the Database

=item * C<excluded_currencies> [OPTIONAL] comma separated currency_code(s) to exclude specific currencies from auto-reject

=back

=cut

sub run {
    my ($self, %args) = @_;

    try {

        my ($locked_withdrawals) = $self->db_load_locked_crypto_withdrawals($args{excluded_currencies} // '');

        $log->debugf('Withdrawals in locked state %s', $locked_withdrawals);

        return 0 unless scalar(@$locked_withdrawals);

        my $withdrawals_today = $self->get_withdrawals_today_per_user();

        my @user_withdraw_pairs = $self->process_locked_withdrawals(
            locked_withdrawals => $locked_withdrawals,
            withdrawals_today  => $withdrawals_today,
            is_dry_run         => $args{is_dry_run},
        );

        my $csv_file_name = $self->csv_export(\@user_withdraw_pairs);
        $self->send_email(attachment => [$csv_file_name]);

    } catch ($e) {
        stats_inc('crypto.payments.autoreject.failure');
        die $log->fatalf("Error while running crypto auto reject script is %s", $e);
    };

    return 1;
}

=head2 user_activity

Perform and collects details related to user activity on platform

Takes the following arguments as named parameters:

=over 4

=item * C<binary_user_id> - user unique identifier from database

=item * C<client_loginid> - Client login id

=item * C<total_withdrawal_amount> - total withdrawal amount requested by user

=item * C<total_withdrawal_amount_today> - total withdrawal amount today

=item * C<withdrawal_amount_in_crypto> - withdrawal amount of this transaction in crypto currency

=item * C<currency_code> - Currency code

=back

=cut

sub user_activity {
    my ($self, %args) = @_;
    my $total_withdrawal_amount_today = $args{total_withdrawal_amount_today} // 0;
    my $withdrawal_amount_in_crypto   = $args{withdrawal_amount_in_crypto}   // 0;
    my $currency_code                 = $args{currency_code};
    my $binary_user_id                = $args{binary_user_id};
    my $client_loginid                = $args{client_loginid};
    my $response                      = {};
    # my $user                          = BOM::User->new(id => $binary_user_id);
    $response->{tag}                                  = TAGS->{high_crypto_deposit};
    $response->{auto_reject}                          = 0;
    $response->{total_withdrawal_amount_today_in_usd} = $total_withdrawal_amount_today;

    my $client_balance = $self->get_client_balance($client_loginid);
    if ($client_balance < $withdrawal_amount_in_crypto) {
        $log->debugf('Client balance %s is lower than the withdrawal amount %s', $client_balance, $withdrawal_amount_in_crypto);
        $response->{tag}           = TAGS->{insufficient_balance};
        $response->{reject_reason} = 'insufficient_balance';
        $response->{auto_reject}   = 1;
        $response->{reject_remark} = $self->generate_reject_remarks(
            reject_reason => $response->{reject_reason},
            extra_info    => $response->{meta_data},
        );
        return $response;
    }

    if ($self->is_client_auto_reject_disabled($client_loginid)) {
        $log->debugf('Auto reject is not enabled for client %s', $client_loginid);
        $response->{tag}         = TAGS->{auto_reject_disable_for_client};
        $response->{auto_reject} = 0;
        return $response;
    }
    my $start_date_to_inspect = Time::Moment->from_epoch(Time::Moment->now->epoch - TIME_RANGE);
    my ($user_payments) = $self->user_payment_details(
        binary_user_id => $binary_user_id,
        from_date      => $start_date_to_inspect->to_string,
    );

    # Skip rejecting payout if there are no deposits via stable payment methods (non-crypto deposits).
    # Why because we do not have to proceed to the next rules where we consider net deposit of stable payment methods.
    if ($user_payments->{count} and $user_payments->{has_stable_method_deposits}) {
        my $all_crypto_net_deposits   = $user_payments->{currency_wise_crypto_net_deposits} // {};
        my $net_crypto_deposit_amount = $all_crypto_net_deposits->{$currency_code}          // 0;
        my $highest_deposited_amount  = $self->find_highest_deposit($user_payments);
        my $mastercard_deposit_amount = $user_payments->{mastercard_deposit_amount} // 0;

        # Skip rejecting payout if the net deposit of crypto and highest non-crypto stable methods are negative
        if (($highest_deposited_amount->{net_amount_in_usd} // 0) < 0 and $net_crypto_deposit_amount < 0) {
            $log->debugf('User\'s net crypto deposit amount & highest deposited amount are both negative values since %s',
                $start_date_to_inspect->to_string);
            $response->{tag}         = TAGS->{crypto_non_crypto_net_deposits_negative};
            $response->{auto_reject} = 0;
            return $response;
        }

        # Reject highest deposited amount is Master Card
        if (($highest_deposited_amount->{net_amount_in_usd} // 0) < $mastercard_deposit_amount
            and $net_crypto_deposit_amount < $mastercard_deposit_amount)
        {
            $log->debugf('User has more mastercard deposits than crypto deposits since %s', $start_date_to_inspect->to_string);
            $response->{tag}           = TAGS->{withdraw_via_ewallet};
            $response->{auto_reject}   = 1;
            $response->{reject_reason} = 'withdraw_via_ewallet';
            $response->{reject_remark} = $self->generate_reject_remarks(
                reject_reason => $response->{reject_reason},
                extra_info    => "e-wallet"
            );
            return $response;
        }

        # Reject payout if the net deposit (deposit - withdrawal) of crypto is less than any other stable payment methods
        # List of stable payment methods are provided by the payments team.
        if (%$highest_deposited_amount and $net_crypto_deposit_amount < $highest_deposited_amount->{net_amount_in_usd}) {
            $log->debugf('User has more Fiat deposits than crypto deposits since %s', $start_date_to_inspect->to_string);
            $response->{tag}                       = TAGS->{highest_deposit_not_crypto};
            $response->{reject_reason}             = 'highest_deposit_method_is_not_crypto';
            $response->{auto_reject}               = 1;
            $response->{suggested_withdraw_method} = $self->map_clean_method_name($highest_deposited_amount->{highest_deposit_method});
            $response->{reject_remark}             = $self->generate_reject_remarks(
                reject_reason => $response->{reject_reason},
                extra_info    => $response->{suggested_withdraw_method});
            return $response;
        }
    } else {
        # We do not return here because we need to validate the next reject rules
        $log->debugf('User has no stable non-crypto deposits since %s', $start_date_to_inspect->to_string);
        $response->{tag}         = TAGS->{no_non_crypto_deposits};
        $response->{auto_reject} = 0;
    }

    # Reject payout if total amount used for trading is less than 25 percent of total deposit amount
    # Total trade amount and deposit amount is calcualted across all the sibling accounts.
    # my $total_user_deposit_amount = $user_payments->{non_crypto_deposit_amount} + $user_payments->{total_crypto_deposits};
    # my $total_trade_volume        = $user->total_trades($start_date_to_inspect);
    # if ($total_trade_volume < $total_user_deposit_amount / 4) {
    #     $log->debugf('Insufficient trading activity since %s', $start_date_to_inspect->to_string);
    #     $response->{tag}           = TAGS->{low_trade};
    #     $response->{reject_reason} = 'low_trade';
    #     $response->{auto_reject}   = 1;
    #     $response->{reject_remark} = $self->generate_reject_remarks(reject_reason => $response->{reject_reason});
    #     return $response;
    # }

    return $response;
}

=head2 db_reject_withdrawal

Perfom database changes to reject the crypto withdrawal

Takes the following arguments as named parameters

=over 4

=item * C<id> - row id for payment record

=back

=cut

sub db_reject_withdrawal {
    my ($self, %args) = @_;

    my $crypto_api = BOM::Platform::CryptoCashier::InternalAPI->new;
    my $response   = $crypto_api->reject_withdrawal(
        [{id => $args{id}, remark => $args{reject_remark}, remark_code => $args{reject_code}, currency_code => $args{currency_code}}]);

    if ($response && ref $response eq 'HASH' && $response->{error}) {
        $log->errorf('Faild to reject the withdrawal request, error: %s', $response->{error}{message_to_client});
        return 0;
    }

    return $response->[0]->{is_success};
}

=head2 auto_update_withdrawal

Reject the crypto withdrawal record if any of the condition satisfies.

Does not invoke the db function if reject is not enabled and will be a dry run

Takes the following arguments as named parameters

=over 4

=item * C<withdrawal_details> - see C<db_load_locked_crypto_withdrawals>'s response

=item * C<is_dry_run> - boolean flag to enable actual reject of payouts, if true, will be a dry run and no db changes will be performed

=item * C<user_details> - contains data returned by C<user_activity>. the return values differ from case to case.

=back

Returns 1 if withdrawal is successfully rejected else returns 0

=cut

sub auto_update_withdrawal {
    my ($self, %args) = @_;
    my $withdrawal_details = $args{withdrawal_details};
    my $is_dry_run         = $args{is_dry_run};
    my $user_details       = $args{user_details};

    if ($is_dry_run) {
        return $log->debugf('Rejection is not enabled (dry_run=1). It will not reject any withdrawals.');
    }

    if ($user_details->{auto_reject}) {
        $log->debugf('Rejecting withdrawal. Details - currency: %s, paymentID: %s.', $withdrawal_details->{currency_code}, $withdrawal_details->{id});
        my $reject_code = $user_details->{reject_reason};
        $reject_code .= '--' . $user_details->{suggested_withdraw_method} if $user_details->{suggested_withdraw_method};
        my ($result) = $self->db_reject_withdrawal(
            id            => $withdrawal_details->{id},
            reject_remark => $user_details->{reject_remark},
            reject_code   => $reject_code,
            currency_code => $withdrawal_details->{currency_code});

        $log->debugf('DB reject withdrawal response %s', $result);

        if ($result) {
            stats_inc('crypto.payments.autoreject.rejected',
                {tags => ['reason:' . $user_details->{tag}, 'currency:' . $withdrawal_details->{currency_code}]});

            stats_count(
                'crypto.payments.autoreject.total_in_usd',
                $withdrawal_details->{amount_in_usd},
                {tags => ['currency:' . $withdrawal_details->{currency_code}]});

            return 1;
        }

    } else {
        stats_inc('crypto.payments.autoreject.non_rejected',
            {tags => ['reason:' . $user_details->{tag}, 'currency:' . $withdrawal_details->{currency_code}]});
    }

    return 0;
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
- Auto reject
- Tag
- Status
- Remarks

=cut

sub csv_export {

    my $self = shift;
    my @data = shift->@*;

    my @csv_headers = (
        "User ID", "Login ID", "Currency", "Amount",
        "Amount requested (in USD)",
        "Total amount requested (in USD)",
        "Total amount requested today (in USD)",
        "Auto reject", "Tag", "Remarks"
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
            $user_details->{total_withdrawal_amount_today_in_usd}, $user_details->{auto_reject},
            $user_details->{tag},                                  $user_details->{reject_remark}];
    }

    mkdir 'autoreject';
    my $csv_file_name = "autoreject/crypto_auto_reject_" . Time::Moment->now->strftime('%Y_%m_%d_%H_%M_%S') . ".csv";
    csv(
        in      => \@csv_rows,
        headers => \@csv_headers,
        out     => $csv_file_name,
    );

    return $csv_file_name;
}

=head2 is_client_auto_reject_disabled

check if reject is disabled for current client

=over 4

=item * C<client_loginid> - Client login id

=back

Returns 1 if client has status code crypto_auto_reject_disabled else returns 0

=cut

sub is_client_auto_reject_disabled {

    my ($self, $client_loginid) = @_;

    my $statuses = $self->client_status(client_loginid => $client_loginid);

    return 1 if any { $_->{status_code} eq 'crypto_auto_reject_disabled' } @$statuses;

    return 0;
}

=head2 generate_reject_remarks

Generate descriptive message as remarks for rejected payouts.

Takes the following arguments as named parameters

=over 4

=item * C<reject_reason> - Reject reason

=item * C<extra_info> - Additional info to be appended with reject remark (For eg: highest deposited payment method)

=back

Returns a string

=cut

sub generate_reject_remarks () {
    my ($self, %args) = @_;

    my $rejection_reason = 'AutoRejected';
    if ($args{reject_reason}) {
        $rejection_reason = sprintf("$rejection_reason - %s", REJECTION_REASONS->{$args{reject_reason}}->{reason});
        $rejection_reason = sprintf($rejection_reason,        $args{extra_info}) if ($args{extra_info});
    }

    return $rejection_reason;
}

1;

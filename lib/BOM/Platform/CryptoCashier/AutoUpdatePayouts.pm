package BOM::Platform::CryptoCashier::AutoUpdatePayouts;

use strict;
use warnings;

=head1 NAME

BOM::Platform::CryptoCashier::AutoUpdatePayouts

=head1 DESCRIPTION

This is a base class for performing Auto Approve and Auto Reject for the crypto withdrawals/payouts

=cut

use Date::Utility;
use Email::Address::UseXS;
use Email::Sender::Transport::SMTP;
use Email::Stuffer;
use JSON::MaybeXS qw(decode_json encode_json);
use LandingCompany::Registry;
use List::Util    qw(first any);
use List::UtilsBy qw(max_by);
use Log::Any      qw($log);
use Syntax::Keyword::Try;

use BOM::Database::ClientDB;
use BOM::Platform::CryptoCashier::InternalAPI;
use BOM::Config::CurrencyConfig;
use BOM::User::Client;

use constant RESTRICTED_CLIENT_STATUS => {
    cashier_locked           => 1,
    disabled                 => 1,
    no_withdrawal_or_trading => 1,
    withdrawal_locked        => 1,
    duplicate_account        => 1,
    closed                   => 1,
    unwelcome                => 1
};

my $doughflow_methods;

=head2 broker_code

Get broker code which was set in the child class constructor

=cut

sub broker_code { shift->{broker_code} }

=head2 client_dbic

Connect to the client db for the broker code in child class constructor

=cut

sub client_dbic {
    my $self = shift;

    return $self->{clientdb}->{$self->broker_code} //= do {

        die 'Invalid broker code.' unless grep { uc($self->broker_code) eq $_ } LandingCompany::Registry->all_real_broker_codes;

        BOM::Database::ClientDB->new({broker_code => $self->broker_code})->db->dbic;
    }
}

=head2 process_locked_withdrawals

Loops over each locked withdrawal, rejects withdrawal requests based on the predefined rules in the description

=over 2

=item * C<locked_withdrawals> see C<db_load_locked_crypto_withdrawals>'s response

=item * C<withdrawals_today> see C<get_withdrawals_today_per_user>'s response

=item * C<is_dry_run> -  Boolean flag to check if this is a dry run

=back

=cut

sub process_locked_withdrawals {
    my ($self, %args) = @_;
    my $count              = 0;
    my $locked_withdrawals = $args{locked_withdrawals};
    my $withdrawals_today  = $args{withdrawals_today};
    my @results;

    foreach my $withdrawal_record (@$locked_withdrawals) {

        my $binary_user_id = $withdrawal_record->{binary_user_id};
        my $client_loginid = $withdrawal_record->{client_loginid};
        my $total_withdrawal_amount_today =
            ($withdrawals_today && $withdrawals_today->{$binary_user_id}) ? $withdrawals_today->{$binary_user_id} : 0;
        $log->debugf('---------- START User ID: %s, Loginid: %s. Requests remaining %s -----------',
            $binary_user_id, $client_loginid, (scalar(@$locked_withdrawals) - $count));

        $count++;
        $log->debugf('Pending withdrawal request details %s', $withdrawal_record);

        my ($user_activity) = $self->user_activity(
            binary_user_id                => $binary_user_id,
            client_loginid                => $client_loginid,
            total_withdrawal_amount       => $withdrawal_record->{amount_in_usd},
            total_withdrawal_amount_today => $total_withdrawal_amount_today,
            currency_code                 => $withdrawal_record->{currency_code},
            withdrawal_amount_in_crypto   => $withdrawal_record->{amount},          # amount in crypto currency
        );

        $log->debugf('User activity summary %s', $user_activity);

        $log->debugf('User ID: %s and Login Id: %s.', $binary_user_id, $client_loginid);

        $self->auto_update_withdrawal(
            user_details       => $user_activity,
            withdrawal_details => $withdrawal_record,
            is_dry_run         => $args{is_dry_run},
        );

        push(
            @results,
            {
                user_details       => $user_activity,
                withdrawal_details => $withdrawal_record
            });
    }
    return @results;
}

=head2 user_payment_details

Get details related to user payments since the specified date

Example usage:
    user_payment_details(binary_user_id => 1, from_date => ...)

Takes the following arguments as named parameters

=over 4

=item * C<binary_user_id> - user unique identifier from database

=item * C<from_date> - date from which payment details are required

=back

Returns a hash ref with the following keys:

=over 4

=item * C<count> - total number of payment records

=item * C<payments> - all the payments records as arrayref of hashes

=item * C<has_reversible_payment> - boolean flag to tell if user has reversible payment

=item * C<last_reversible_deposit> - last reversible deposit record, detailed description of the record in C<doughflow_user_payments>'s POD

=item * C<reversible_deposit_amount> - total amount of reversible deposit in USD

=item * C<reversible_withdraw_amount> - total amount of reversible withdrawal in USD

=item * C<non_crypto_deposit_amount> - total non crypto deposit amount in USD

=item * C<non_crypto_withdraw_amount> - total non crypto withdraw amount in USD

=item * C<total_crypto_deposit> - total crypto deposit amount in USD

=item * C<method_wise_total_deposits> -  methodwise total deposits of all gateways like doughflow, ctc, payment_agent_transfer

=item * C<method_wise_net_deposits> - methodwise net deposit of each doughflow method instead of doughflow as a whole, payment_agent_transfer_p2p.

=item * C<currency_wise_crypto_net_deposits> - currency wise net deposits of all crypto deposits through crypto cashier


=back

=cut

sub user_payment_details {
    my ($self, %args) = @_;

    my ($user_payments) = $self->user_payments(
        binary_user_id => $args{binary_user_id},
        from_date      => $args{from_date},
    );

    my $has_reversible_payment                  = 0;
    my $total_deposit_amount_in_usd             = 0;
    my $total_reversible_deposit_amount_in_usd  = 0;
    my $total_withdraw_amount_in_usd            = 0;
    my $total_reversible_withdraw_amount_in_usd = 0;
    my $total_mastercard_deposit_amount         = 0;
    my $last_reversible_deposit;
    my $method_wise_net_deposits          = {};
    my $currency_wise_crypto_net_deposits = {};
    my $has_stable_method_deposits        = 0;
    my $total_crypto_deposits             = 0;

    my @crypto_payments = grep { $_->{p_method} eq 'ctc' } $user_payments->@*;

    $total_crypto_deposits += $_->{total_deposit_in_usd} for @crypto_payments;
    $currency_wise_crypto_net_deposits->{$_->{currency_code}} = $_->{net_deposit} for @crypto_payments;

    #get non crypto user payments
    my @user_payments = grep { $_->{p_method} ne 'ctc' } $user_payments->@*;
    foreach my $payment (@user_payments) {

        $log->debugf('User non-crypto payments %s', $payment);

        my $is_reversible_payment = $payment->{is_reversible};
        $has_reversible_payment ||= $is_reversible_payment;
        if ($is_reversible_payment) {
            $last_reversible_deposit //= $payment;
            $total_reversible_deposit_amount_in_usd  += $payment->{total_deposit_in_usd};
            $total_reversible_withdraw_amount_in_usd += $payment->{total_withdrawal_in_usd};
        }

        $total_deposit_amount_in_usd  += $payment->{total_deposit_in_usd};
        $total_withdraw_amount_in_usd += $payment->{total_withdrawal_in_usd};

        $total_mastercard_deposit_amount += $payment->{net_deposit} if lc($payment->{p_method}) eq 'mastercard';

        # Net deposits needs to be calculated only for the stable payment methods.
        if ($self->is_stable_payment_method($payment->{p_method})) {
            $has_stable_method_deposits = 1 if ($payment->{total_deposit_in_usd} > 0);
            $method_wise_net_deposits->{$payment->{p_method}} += $payment->{net_deposit};
            $payment->{is_stable_method} = 1;
        }
    }

    return {
        count                             => scalar(@user_payments),
        payments                          => \@user_payments,
        has_reversible_payment            => $has_reversible_payment,
        last_reversible_deposit           => $last_reversible_deposit,
        reversible_deposit_amount         => $total_reversible_deposit_amount_in_usd,
        reversible_withdraw_amount        => $total_reversible_withdraw_amount_in_usd,
        non_crypto_deposit_amount         => $total_deposit_amount_in_usd,
        non_crypto_withdraw_amount        => $total_withdraw_amount_in_usd,
        total_crypto_deposits             => $total_crypto_deposits,
        method_wise_net_deposits          => $method_wise_net_deposits,
        mastercard_deposit_amount         => $total_mastercard_deposit_amount,
        currency_wise_crypto_net_deposits => $currency_wise_crypto_net_deposits,
        has_stable_method_deposits        => $has_stable_method_deposits
    };

}

=head2 is_stable_payment_method

Check if the payment method belongs to the stable methods.

=cut

sub is_stable_payment_method {
    my ($self, $payment_method) = @_;

    my $stable_methods = $self->get_stable_payment_methods();

    return 0 unless ($payment_method);

    if ($stable_methods->{lc($payment_method)}) {
        return 1;
    }

    return 0;
}

=head2 user_status

Get user status records from the database

Takes the following arguments as named parameters

=over 4

=item * C<binary_user_id> - user unique identifier from database

=back

Returns all the user status records as array of hashes

=cut

sub user_status {
    my ($self, %args) = @_;

    my ($user_status) = $self->client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                q{SELECT distinct(cs.status_code)
            FROM betonmarkets.client_status cs
            JOIN betonmarkets.client c ON cs.client_loginid = c.loginid
            WHERE c.binary_user_id = ?},
                {Slice => {}},
                $args{binary_user_id});
        });

    return $user_status // [];
}

=head2 client_status

Get client status records from the database

Takes the following arguments as named parameters

=over 4

=item * C<client_loginid> - client login id

=back

Returns all the client status records for the login id as array of hashes

=cut

sub client_status {
    my ($self, %args) = @_;
    my ($client_status) = $self->client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                q{SELECT distinct(status_code)
            FROM betonmarkets.client_status
            WHERE client_loginid IN
                (?)},
                {Slice => {}},
                $args{client_loginid});
        });

    return $client_status // [];
}

=head2 user_payments

Get user's doughflow, payment_agent_transfer & p2p payments records from the database

Takes the following arguments as named parameters

=over 4

=item * C<binary_user_id> - user unique identifier from database

=item * C<from_date> - string, date from which payments records are to be fetched

=back

Returns payment records as array of hashes

Each payment record has the following fields

=over 4

=item * C<p_method> Payment gateway codes (ctc, p2p) or payment method for doughflow payments (PerfectM, Skrill)

=item * C<currency_code> payment's currency code, e.g. USD, GBP, ETH, BTC

=item * C<total_deposit_in_usd> total deposit amount in usd grouped by payment method and currency code

=item * C<total_withdrawal_in_usd> total withdrawal amount in usd grouped by payment method and currency code

=item * C<net_deposit> net deposit (deposit - withdrawal) grouped by payment method and currency code

=item * C<count> Count

=item * C<is_reversible> Returns a boolean whether the payment is reversible or not

=item * C<payment_time> Most recent payment time

=back

=cut

sub user_payments {
    my ($self, %args) = @_;

    return $self->client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(q{SELECT  * FROM payment.get_payment_stats_by_user(?, ?)}, {Slice => {}}, $args{binary_user_id}, $args{from_date});
        });
}

=head2 user_restricted

Check if user has one of the restricted status

Takes the following arguments as named parameters

=over 4

=item * C<binary_user_id> - user unique identifier from database

=back

Returns status code if user has one of the restricted status else returns undef

=cut

sub user_restricted {
    my ($self, %args) = @_;

    my ($status) = $self->user_status(%args);

    return first { RESTRICTED_CLIENT_STATUS()->{$_->{status_code}} } @$status;
}

=head2 db_load_locked_crypto_withdrawals

Get all the locked crypto withdrawal requests

Returns all the locked records as array of hashrefs, each one contains:

=over 4

=item * C<excluded_currencies> [OPTIONAL] comma separated currency_code(s) to exclude specific currencies from auto-refusal

=back

returns the withdrawals records as array of hashes

Each payment record has the following fields

=over 4

=item * same fields of the database table C<payment.cryptocurrency>

=item * C<binary_user_id> id of the binary user

=item * C<amount_in_usd> - payment's amount in USD

=item * C<total_withrawal_amount_in_usd> computed as the sum of all withdrawal's amount in usd per binary user

=back

=cut

sub db_load_locked_crypto_withdrawals {
    my ($self, $excluded_currencies) = @_;

    my $crypto_api          = BOM::Platform::CryptoCashier::InternalAPI->new;
    my $response            = $crypto_api->list_locked_crypto_withdrawals($excluded_currencies // '');
    my $pending_withdrawals = [];
    if ($response && ref $response eq 'HASH' && $response->{error}) {
        $log->errorf('Faild to get the pending withdrawal requests, error: %s', $response->{error}{message_to_client});
    } else {
        $pending_withdrawals = $response;
    }

    return [] unless (scalar $pending_withdrawals->@*);

    my $pending_withdrawals_det = $self->client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                q{SELECT * from betonmarkets.get_total_withdrawal_amounts_per_client_in_usd(?)},
                {Slice => {}},
                encode_json($pending_withdrawals));
        });

    return $pending_withdrawals_det;
}

=head2 get_withdrawals_today_per_user

Get withdrawals initiated today from cryptodb & pass them to clientdb to get withdrawal amounts in usd per binary_user_id

=over 4

=back

returns withdrawals total amounts in usd per binary_user_id

=cut

sub get_withdrawals_today_per_user {
    my $self              = shift;
    my $withdrawals_today = $self->db_load_total_withdrawals_today();
    return {} unless (scalar $withdrawals_today->@*);

    my $withdrawals_today_in_usd = $self->db_load_withdrawals_per_user_in_usd($withdrawals_today);
    my %withdrawals_per_user;
    for my $withdrawal (@$withdrawals_today_in_usd) {
        $withdrawals_per_user{$withdrawal->{binary_user_id}} = $withdrawal->{total_withdrawal_amount_in_usd};
    }
    return \%withdrawals_per_user;
}

=head2 db_load_total_withdrawals_today

Get all the locked crypto withdrawal initaited today except those having current status 'ERROR','CANCELLED' or 'REJECTED'

=over 4

=back

arrayref of hashrefs of crypto withdrawal records

=cut

sub db_load_total_withdrawals_today {
    my $self = shift;

    my $from_date = Date::Utility->new->truncate_to_day;
    my $to_date   = $from_date->plus_time_interval('24h');

    my $crypto_api = BOM::Platform::CryptoCashier::InternalAPI->new;
    my $response   = $crypto_api->list_total_withdrawals_by_date($from_date->date_yyyymmdd, $to_date->date_yyyymmdd);

    if ($response && ref $response eq 'HASH' && $response->{error}) {
        $log->errorf('Faild to get the total withdrawal requests, error: %s', $response->{error}{message_to_client});
        return [];
    }
    return $response;
}

=head2 db_load_withdrawals_per_user_in_usd

Get total amount per user in usd for all crypto withdrawals initiated today

=over 4

=item * C<withdrawals_today> - see C<db_load_total_withdrawals_today>'s response

=back

arrayref of withdrawals_today with binary_user_id & amounts in usd

=cut

sub db_load_withdrawals_per_user_in_usd {

    my ($self, $withdrawals_today) = @_;

    return [] unless ($withdrawals_today);
    return $self->client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                q{SELECT * from betonmarkets.get_total_withdrawal_amounts_per_client_in_usd(?);},
                {Slice => {}},
                encode_json($withdrawals_today));
        });
}

=head2 risk_calculation

Performs risk calculation based on net deposit

Example usage:
    risk_calculation(deposit => 100, withdraw => 50, acceptable_percentage => 10);

Takes the following arguments as named parameters

=over 4

=item * C<deposit> - total deposit amount in USD

=item * C<withdraw> - total withdraw amount in USD

=item * C<acceptable_percentage> - same as C<run>

=back

Returns a hash ref with the following structure:

=over 4

=item * C<is_acceptable> - if net deposit percentage is acceptable

=item * C<risk_percentage> - net deposit percentage

=back

=cut

sub risk_calculation {
    my ($self, %args) = @_;

    my $acceptable_percentage = $args{acceptable_percentage};
    my $deposit               = $args{deposit};
    my $withdraw              = $args{withdraw};

    return {
        is_acceptable   => 0,
        risk_percentage => 0
    } unless $deposit;

    my $risk_percentage = (($deposit - abs($withdraw)) / $deposit) * 100;

    return {
        risk_percentage => $risk_percentage,
        is_acceptable   => $risk_percentage < $acceptable_percentage ? 1 : 0
    };
}

=head2 find_highest_deposit

Find the payment method with highest deposit amount from a hashref

=over 4

=item * C<methodwise_net_deposits> - hashref of deposits

=back

returns hashref with keys highest_deposit_method and net_amount_in_usd

=cut

sub find_highest_deposit {

    my ($self, $args) = @_;
    my $response               = {};
    my $payments               = $args->{payments};
    my @stable_payment_methods = (
        sort { Date::Utility->new($b->{payment_time})->epoch <=> Date::Utility->new($a->{payment_time})->epoch }
        grep { $_->{is_stable_method} } $payments->@*
    );
    my $stable_net_deposits = $args->{method_wise_net_deposits};
    # If there are any payment methods having equal net deposit, highest will be chosen randomly.
    my $highest_deposit = max_by { $stable_net_deposits->{$_} } keys $stable_net_deposits->%*;

    return $response unless $highest_deposit;

    # Since stable_net_deposits is a hash, order cannot be predicted.
    # Hence we will again loop through the sorted stable payment methods array in order to
    # find the latest payment method with highest net deposit.
    foreach my $payment (@stable_payment_methods) {
        if ($stable_net_deposits->{$payment->{p_method}} >= $stable_net_deposits->{$highest_deposit}) {
            $response->{highest_deposit_method} = $payment->{p_method};
            $response->{net_amount_in_usd}      = $stable_net_deposits->{$payment->{p_method}};
            last;
        }
    }
    return $response;

}

=head2 send_email

Required environment variables are:

- MAIL_HOST
- MAIL_PORT
- SENDER_EMAIL
- RECIPIENT_EMAIL

Optional environment variables are:

- SASL_USERNAME
- SASL_PASSWORD

Takes the following arguments as named parameters

=over 4

=item * C<attachment> - path to the file to be sent with the email

=back

=cut

sub send_email {
    my ($self, %args) = @_;

    # check for mandatory environment variables
    if (my @undefined_variables = grep { !$ENV{$_} } qw(MAIL_HOST MAIL_PORT SENDER_EMAIL RECIPIENT_EMAIL)) {
        return $log->error(
            'The following required environment variables are empty: ' . join(', ', sort @undefined_variables) . '. Not sending any email.');
    }

    # optional environment variables
    if (grep { !$ENV{$_} } qw/SASL_USERNAME SASL_PASSWORD/) {
        $log->debug('One or more of the optional environment variables (SASL_USERNAME, SASL_PASSWORD) are empty');
    }

    # send email
    try {
        my $email_subject = "Analysis of pending crypto withdrawals requests for fraud prevention";
        my $sender_email  = $ENV{SENDER_EMAIL};

        $log->debugf('Environment variables for sending email');
        $log->debugf('%s %s', $_, $ENV{$_}) foreach qw(MAIL_HOST MAIL_PORT SENDER_EMAIL);
        my $recipient     = $ENV{RECIPIENT_EMAIL};
        my $email_stuffer = Email::Stuffer->from($sender_email)->transport(
            Email::Sender::Transport::SMTP->new({
                    host          => $ENV{MAIL_HOST},
                    port          => $ENV{MAIL_PORT},
                    sasl_username => $ENV{SASL_USERNAME} // '',
                    sasl_password => $ENV{SASL_PASSWORD} // '',
                }))->to($recipient)->subject($email_subject)->text_body('Please find attached the list of pending withdrawal request with details.');

        for my $attach_file (@{$args{attachment}}) {
            $email_stuffer->attach_file($attach_file);
        }

        my $email_status = $email_stuffer->send();
        if ($email_status) {
            return $log->infof('Mail sent successfully at email address [%s]', $recipient);
        } else {
            return $log->errorf('Failed to send the email at email address [%s]', $recipient);
        }
    } catch ($e) {
        return $log->errorf('Error sending email. %s', $e);
    }

    return 0;
}

=head2 map_clean_method_name

Returns proper payment method name if exists in STABLE_PAYMENT_METHODS . This will be used to populate the client email and internal csv file

=cut

sub map_clean_method_name {
    my ($self, $method) = @_;

    my $lc_method = lc($method);

    my $stable_methods = $self->get_stable_payment_methods();

    return $stable_methods->{$lc_method} // $lc_method;
}

=head2 get_client_balance

Returns the client's balance.

=over 4

=item * C<$client_loginid> - Client's loginid

=back

=cut

sub get_client_balance {
    my ($self, $client_loginid) = @_;

    my $client = BOM::User::Client->new({loginid => $client_loginid});
    return $client->default_account->balance;
}

=head2 get_stable_payment_methods

Returns the stable payment methods.

=cut

sub get_stable_payment_methods {
    my $self = shift;

    return $self->{stable_payment_methods} //= do {
        decode_json(BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('stable_payment_methods') // '{}');
    }
}

1;

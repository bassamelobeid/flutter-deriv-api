package BOM::Cryptocurrency::Helper;

use strict;
use warnings;

use BOM::Config::Redis;
use BOM::CTC::Database;

use constant {REPROCESS_KEY_TTL => 300};

use Exporter qw/import/;

our @EXPORT_OK = qw(reprocess_address get_crypto_withdrawal_pending_total get_crypto_transactions);

=head2 reprocess_address

Reprocess the given address and returns the result.

Takes 2 parameters:

=over

=item * C<currency_wrapper> - A currency object from L<BOM::CTC::Currency> module

=item * C<address_to_reprocess> - The address to be prioritised

=back

Returns the result as a string containing HTML tags.

=cut

sub reprocess_address {
    my ($currency_wrapper, $address_to_reprocess) = @_;

    return _render_message(0, "Address not found.")
        unless ($address_to_reprocess);

    $address_to_reprocess =~ s/^\s+|\s+$//g;
    return _render_message(0, "Invalid address format.")
        unless ($currency_wrapper->is_valid_address($address_to_reprocess));

    my $redis_reader = BOM::Config::Redis::redis_replicated_read();
    my $redis_key    = "Reprocess::$address_to_reprocess";
    if ($redis_reader->get($redis_key)) {
        my $redis_key_ttl = $redis_reader->ttl($redis_key);
        return _render_message(0, "The address $address_to_reprocess is already reprocessed recently, please try after $redis_key_ttl seconds.");
    }

    my $reprocess_result = $currency_wrapper->reprocess_address($address_to_reprocess);
    return _render_message(0, $reprocess_result->{message})
        unless $reprocess_result->{is_success};

    BOM::Config::Redis::redis_replicated_write()->set(
        $redis_key => 1,
        EX         => REPROCESS_KEY_TTL,
    );
    return _render_message(1, "Requested reprocessing for $address_to_reprocess");
}

=head2 _render_message

Renders the result output with proper HTML tags and color.

=over

=item * C<is_success> - A boolean value whether it is a success or failure

=item * C<message> - The message text

=back

Returns the message as a string containing HTML tags.

=cut

sub _render_message {
    my ($is_success, $message) = @_;

    my ($color, $title) = $is_success ? ('green', 'SUCCESS') : ('red', 'ERROR');
    return "<p style='color: $color;'><strong>$title:</strong> $message</p>";
}

=head2 get_crypto_withdrawal_pending_total

Get withdrawal total values for all C<LOCKED> transactions of a crypto currency.

=over

=item * C<currency> - Currency code to check the withdrawals for

=back

Returns a hashref including the following keys:

=over

=item * C<pending_withdrawal_amount> - Total amount of C<LOCKED> withdrawals for the C<currency>

=item * C<pending_estimated_fee> - Total amount of estimated fees for C<LOCKED> withdrawals

=back

=cut

sub get_crypto_withdrawal_pending_total {
    my ($currency) = @_;

    my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

    my ($pending_withdrawal_amount, $pending_estimated_fee) = $dbic->run(
        fixup => sub {
            $_->selectrow_array(
                "SELECT COALESCE(SUM(amount), 0), COALESCE(SUM(estimated_fee), 0)
                FROM payment.cryptocurrency
                WHERE
                        currency_code = ?
                    AND blockchain_txn IS NULL
                    AND status = 'LOCKED'
                    AND transaction_type='withdrawal'",
                undef, $currency
            );
        });

    return {
        pending_withdrawal_amount => $pending_withdrawal_amount,
        pending_estimated_fee     => $pending_estimated_fee,
    };
}

=head2 get_crypto_transactions

Get crypto currency transactions from DB based on the given parameters.

=over 4

=item * C<trx_type> - The transaction type. Valid values are C<deposit> and C<withdrawal>

=item * C<params> - A hash containing the query params to filter or limit by. Can include any number of the following keys:

=over 4

=item * C<loginid> - The client's loginid

=item * C<address> - The crypto address

=item * C<currency_code> - The currency code

=item * C<status> - The status code of the transaction

=item * C<limit> - An integer to limit the returned transactions by

=item * C<offset> - An integer which denotes the offset value of the results

=back

=back

Returns an arrayref list of transactions that meet the criteria. If nothing found, will return an empty arrayref.

=cut

sub get_crypto_transactions {
    my ($trx_type, %params) = @_;

    my $function_name = $trx_type eq 'deposit' ? 'payment.ctc_bo_get_deposit' : 'payment.ctc_bo_get_withdrawal';

    my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

    return $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM $function_name(?, ?, ?, ?, ?, ?, ?)",
                {Slice => {}},
                @params{qw(loginid address currency_code status limit offset sort_direction)});
        }) // [];
}

=head2 get_withdrawal_error_txn

This sub queries the withdrawal transactions with the "error" status of the selected currency

=cut

sub get_withdrawal_error_txn {

    my ($currency_code) = @_;

    my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

    return $dbic->run(
        fixup => sub {
            $_->selectall_hashref("SELECT * from payment.ctc_get_error_withdrawal_transactions(?::TEXT)", 'id', {}, $currency_code);
        }) // [];

}

=head2 revert_txn_status_to_processing

This sub changes the withdrawal transaction's status from "ERROR" to "PROCESSING" by getting the id

=cut

sub revert_txn_status_to_processing {
    my ($txn_id, $currency, $prev_approver, $staff) = @_;

    my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

    $dbic->run(
        fixup => sub {
            $_->do("SELECT * from payment.ctc_reset_error_to_processing(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT)",
                undef, $txn_id, $currency, $prev_approver, $staff);
        });
}

1;

package BOM::Cryptocurrency::Helper;

use strict;
use warnings;

use BOM::Config::Redis;
use BOM::Database::ClientDB;

use constant {PRIORITIZE_KEY_TTL => 300};

use Exporter qw/import/;

our @EXPORT_OK = qw(prioritize_address get_crypto_withdrawal_pending_total get_crypto_transactions);

=head2 prioritize_address

Prioritizes the given address and returns the result.

Takes 2 parameters:

=over

=item * C<currency_wrapper> - A currency object from L<BOM::CTC::Currency> module

=item * C<prioritize_address> - The address to be prioritised

=back

Returns the result as a string containing HTML tags.

=cut

sub prioritize_address {
    my ($currency_wrapper, $prioritize_address) = @_;

    return _render_message(0, "Address not found.")
        unless ($prioritize_address);

    $prioritize_address =~ s/^\s+|\s+$//g;
    return _render_message(0, "Invalid address format.")
        unless ($currency_wrapper->is_valid_address($prioritize_address));

    my $redis_reader = BOM::Config::Redis::redis_replicated_read();
    my $redis_key    = "Prioritize::$prioritize_address";
    if ($redis_reader->get($redis_key)) {
        my $redis_key_ttl = $redis_reader->ttl($redis_key);
        return _render_message(0, "The address $prioritize_address is already prioritised, please try after $redis_key_ttl seconds.");
    }

    my $prioritize_result = $currency_wrapper->prioritize_address($prioritize_address);
    return _render_message(0, $prioritize_result->{message})
        unless $prioritize_result->{is_success};

    BOM::Config::Redis::redis_replicated_write()->set(
        $redis_key => 1,
        EX         => PRIORITIZE_KEY_TTL,
    );
    return _render_message(1, "Requested priority for $prioritize_address");
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

=item * C<broker> - Broker code

=item * C<currency> - Currency code to check the withdrawals for

=back

Returns a hashref including the following keys:

=over

=item * C<pending_withdrawal_amount> - Total amount of C<LOCKED> withdrawals for the C<currency>

=item * C<pending_estimated_fee> - Total amount of estimated fees for C<LOCKED> withdrawals

=back

=cut

sub get_crypto_withdrawal_pending_total {
    my ($broker, $currency) = @_;

    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
    my $dbic = $clientdb->db->dbic;

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

=item * C<broker> - Broker code

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
    my ($broker, $trx_type, %params) = @_;

    my $function_name = $trx_type eq 'deposit' ? 'payment.ctc_bo_get_deposit' : 'payment.ctc_bo_get_withdrawal';

    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});

    return $clientdb->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM $function_name(?, ?, ?, ?, ?, ?)",
                {Slice => {}},
                @params{qw(loginid address currency_code status limit offset)});
        }) // [];
}

1;

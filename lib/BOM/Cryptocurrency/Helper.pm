package BOM::Cryptocurrency::Helper;

use strict;
use warnings;
no indirect;

use BOM::Backoffice::Request;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Database::ClientDB;

use Exporter qw/import/;

our @EXPORT_OK = qw(render_message has_manual_credit);

=head2 render_message

Renders the result output with proper HTML tags and color.

=over

=item * C<$is_success> - A boolean value whether it is a success or failure

=item * C<$message> - The message text

=back

Returns the message as a string containing HTML tags.

=cut

sub render_message {
    my ($is_success, $message) = @_;

    my ($class, $title) = $is_success ? ('success', 'SUCCESS') : ('error', 'ERROR');
    return "<p class='$class'><strong>$title:</strong> $message</p>";
}

=head2 has_manual_credit

Check if we have credit the client account manually before or not for the passed address.

=over 4

=item * C<address>        - The address to be prioritised

=item * C<currency_code>  - The currency code of the address

=item * C<client_loginid> - The client's account login id

=back

Returns 1 if has manual credit or undef otherwise

=cut

sub has_manual_credit {
    my ($address, $currency_code, $client_loginid) = @_;

    my $clientdb_dbic = my $db = BOM::Database::ClientDB->new({client_loginid => $client_loginid})->db->dbic;

    my $result = $clientdb_dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT payment.ctc_check_address_manual_credit(?, ?, ?)');
            $sth->execute($address, $currency_code, $client_loginid);
            return $sth->fetchrow_hashref;
        });

    return $result->{ctc_check_address_manual_credit};
}

1;

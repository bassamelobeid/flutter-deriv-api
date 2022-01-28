# This file acts as a wrapper for bom-cryptocurrency calls.
# It should only delegate the calls and MUST NOT use any logic related to bom-cryptocurrency

package BOM::Cryptocurrency::Helper;

use strict;
use warnings;
no indirect;

use Exporter qw/import/;

our @EXPORT_OK = qw(reprocess_address);

=head2 reprocess_address

Reprocess the given address and returns the result.

Takes 2 parameters:

=over

=item * C<currency_wrapper> - A currency object from L<BOM::CTC::Currency> module

=item * C<$address_to_reprocess> - The address to be prioritised (string)

=back

Returns the result as a string containing HTML tags.

=cut

sub reprocess_address {
    my ($currency_wrapper, $address_to_reprocess) = @_;

    my $reprocess_result = $currency_wrapper->reprocess_address($address_to_reprocess);

    return _render_message($reprocess_result->{is_success}, $reprocess_result->{message});
}

=head2 _render_message

Renders the result output with proper HTML tags and color.

=over

=item * C<$is_success> - A boolean value whether it is a success or failure

=item * C<$message> - The message text

=back

Returns the message as a string containing HTML tags.

=cut

sub _render_message {
    my ($is_success, $message) = @_;

    my ($class, $title) = $is_success ? ('success', 'SUCCESS') : ('error', 'ERROR');
    return "<p class='$class'><strong>$title:</strong> $message</p>";
}

1;

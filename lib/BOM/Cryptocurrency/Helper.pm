package BOM::Cryptocurrency::Helper;

use strict;
use warnings;

use BOM::Config::Redis;
use constant {PRIORITIZE_KEY_TTL => 300};

use Exporter qw/import/;

our @EXPORT_OK = qw(prioritize_address);

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

1;

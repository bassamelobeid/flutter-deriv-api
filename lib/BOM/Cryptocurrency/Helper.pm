package BOM::Cryptocurrency::Helper;

use strict;
use warnings;

use BOM::Config::RedisReplicated;
use constant {PRIORITIZE_KEY_TTL => 300};

use Exporter qw/import/;

our @EXPORT_OK = qw(prioritize_address);

=head2 prioritize_address

prioritize_address the address and print the result

Takes 2 parameters:

=over

=item * C<$currency_wrapper> - a currency object from BOM::CTC::Currency module

=item * C<$prioritize_address> - The address need to prioritize it

=back

Print the result

=cut

sub prioritize_address {
    my ($currency_wrapper, $prioritize_address) = @_;

    if ($prioritize_address) {
        $prioritize_address =~ s/^\s+|\s+$//g;
        if ($currency_wrapper->is_valid_address($prioritize_address)) {
            my $redis_reader = BOM::Config::RedisReplicated::redis_read();
            unless ($redis_reader->get("Prioritize::" . $prioritize_address)) {
                my $status = $currency_wrapper->prioritize_address($prioritize_address);
                if ($status) {
                    my $writer = BOM::Config::RedisReplicated::redis_write();
                    $writer->set(
                        "Prioritize::" . $prioritize_address => 1,
                        EX                                   => PRIORITIZE_KEY_TTL
                    );
                    print "<p style='color:green'><strong>SUCCESS: Requested priority for $prioritize_address</strong></p>";
                } else {
                    print "<p style='color:red'><strong>ERROR: can't prioritize for $prioritize_address</strong></p>";
                }
            } else {
                my $redis_key_ttl = $redis_reader->ttl("Prioritize::" . $prioritize_address);
                print
                    "<p style='color:red'><strong>ERROR: The address $prioritize_address is already prioritised, please try after $redis_key_ttl seconds</strong></p>";
            }
        } else {
            print "<p style='color:red'><strong>ERROR: invalid address format</strong></p>";
        }
    } else {
        print "<p style=\"color:red\"><strong>ERROR: Address not found</strong></p>";
    }
}

1;

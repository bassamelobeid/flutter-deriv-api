package BOM::Test::Helper::Utility;

use strict;
use warnings;

use String::Random qw(random_regex);

use Exporter qw/import/;
our @EXPORT_OK = qw(random_email_address random_phone);

=head2 random_email_address($opts)

It generates a randomly generated email address which you can use in the tests.

=over 4

=item * C<email>:optional - If you pass the email it will replace with the email part
=item * C<domain>:optional - If you pass the domain it will replace with the domain part otherwise it uses binary.com/deriv.com

=back

Returns a random email address string.

=cut

sub random_email_address {
    my $opts = shift;

    # Using company's domains to prevent hitting any possible existing domain out there.
    my @domains        = ('binary.com', 'deriv.com');
    my %default_values = (
        email  => random_regex('[a-zA-Z0-9]{15,30}'),
        domain => splice(@domains, rand @domains, 1),
    );

    my %email_address = (%default_values, $opts ? $opts->%* : ());

    return $email_address{email} . '@' . $email_address{domain};
}

=head2 random_phone()

It generates a random phone address which you can use in the tests.

=over 4

=item C<valid>:Boolean

If you pass C<False> you will receive an invalid phone number otherwise you will receive a valid phone number.

=back

Returns a randomly generated valid or invalid phone number string.

=cut

sub random_phone {
    my $generate_valid_number = shift // 1;
    my $length                = $generate_valid_number ? 20 : 5;
    my $regex                 = sprintf('\d{%d}', $length);

    return '+' . random_regex($regex);
}

1;

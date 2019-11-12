package BOM::User::Phone;

use Number::Phone;

=head1 Description

This file handles all things related to user's phone number

=cut

use strict;
use warnings;

=head2 format_phone

Given a phone number, parse it to a standardized format via Number::Phone

=cut

sub format_phone {
    my ($phone) = @_;

    # Number::Phone does not accept the 00 convention, so we map 00 to +
    $phone =~ s/^00/+/;

    my $phone_obj = Number::Phone->new($phone);
    # To keep numbers unique for duplicate check, we retain only the leading + and numbers
    my $formatted_phone = $phone_obj ? $phone_obj->format =~ s{[^0-9+]+}{}gr : '';

    return $formatted_phone;
}

1;

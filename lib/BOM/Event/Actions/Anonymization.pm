package BOM::Event::Actions::Anonymization;

use strict;
use warnings;

=head2 start

Initiates the removal of a client's personally identifiable information from
    Binary's systems.

=over 4

=item * C<loginid> - login id of client to trigger anonymization on

=back

=cut

sub start {
    my $data    = shift;
    my $loginid = $data->{loginid};
    return undef unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid});
    return undef unless $client;

    return 1;
}

1;

package BOM::User::Documents;

use strict;
use warnings;
use Moo;

=head1 NAME

BOM::User::Documents - A class that manages the documents at userdb level.

Not to be confused with L<BOM::User::Client::AuthenticationDocuments> handling the
B<betonmarkets.client_authentication_document> table.

=cut

=head2 user

The C<BOM::User:> instance, a little convenience for operations that might require this reference.

=cut

has user => (
    is       => 'ro',
    required => 1,
    weak_ref => 1,
);

=head2 poi_claim

Tries to claim the ownership of the specified POI document

=over 4

=item * C<$type> - the type of the document

=item * C<$number> - the number of the document

=item * C<$country> - the country of the document

=back

Returns C<undef>.

=cut

sub poi_claim {
    my ($self, $type, $number, $country) = @_;

    my $dbic = $self->user->dbic;

    $dbic->run(
        fixup => sub {
            return $_->do(
                "SELECT * FROM users.add_poi_document(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT)",
                {Slice => {}},
                $self->user->id, $type, $number, $country
            );
        });

    return undef;
}

=head2 poi_ownership

Determines the owner of the specified POI document

=over 4

=item * C<$type> - the type of the document

=item * C<$number> - the number of the document

=item * C<$country> - the country of the document

=back

Returns the binary user id of the client who owns the document, C<undef> if no one does.

=cut

sub poi_ownership {
    my ($self, $type, $number, $country) = @_;

    my $dbic = $self->user->dbic;

    my ($binary_user_id) = $dbic->run(
        fixup => sub {
            return $_->selectrow_array("SELECT * FROM users.get_poi_document(?::TEXT, ?::TEXT, ?::TEXT)", {Slice => {}}, $type, $number, $country);
        });

    return $binary_user_id;
}

=head2 poi_free

Frees the specified document.

=over 4

=item * C<$type> - the type of the document

=item * C<$number> - the number of the document

=item * C<$country> - the country of the document

=back

Returns C<undef>

=cut

sub poi_free {
    my ($self, $type, $number, $country) = @_;

    my $dbic = $self->user->dbic;

    $dbic->run(
        fixup => sub {
            return $_->do(
                "SELECT * FROM users.del_poi_document(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT)",
                {Slice => {}},
                $self->user->id, $type, $number, $country
            );
        });

    return undef;
}

1;

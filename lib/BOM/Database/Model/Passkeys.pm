package BOM::Database::Model::Passkeys;

use Moose;
use BOM::Database::UserDB;
use BOM::Config;

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_dbic

build dbic object for userdb

=cut

sub _build_dbic {
    return BOM::Database::UserDB::rose_db()->dbic;
}

=head2 insert_into_passkeys

This method inserts a row into the passkeys.details table.

=over 4

=item * - C<self> The instance of the Passkeys object.

=item * - C<passkeys_obj> - Hashref of detail parameters in passkeys 

=back

=cut

sub insert_into_passkeys {
    my ($self, $passkeys_obj) = @_;

    $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                "INSERT INTO passkeys.credential (passkey_id, binary_user_id, public_key, attestation_data, device, name, transport) 
            VALUES ( ?, ?, ?, ?, ?, ?, ?)"
            );
            $sth->execute($passkeys_obj->@{qw/passkey_id binary_user_id public_key attestation_data device name transport/});
        });
}

=head2 get_passkeys_by_user_id

This method retrieves the passkey details for a specific user.

=over 4

=item * - C<self> The instance of the Passkeys object.

=item * - C<user_id> - binary user id of user to fetch passkey details against it

=back

=cut

sub get_passkeys_by_user_id {
    my ($self, $user_id) = @_;

    my $passkeys_result = $self->dbic->run(
        fixup => sub {
            my $query = $_->prepare("SELECT * FROM passkeys.credential WHERE binary_user_id = ?");
            $query->execute($user_id);
            my $response_data = $query->fetchall_hashref('id');
            return $response_data;
        });
    return $passkeys_result;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

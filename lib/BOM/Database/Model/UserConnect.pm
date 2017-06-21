package BOM::Database::Model::UserConnect;

use Moose;
use BOM::Database::UserDB;
use JSON;

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbic {
    return BOM::Database::UserDB::rose_db->dbic;
}

# TODO chylli/dbix_connector
# should remove this atribute after the whole dbix_connector project finished

sub dbh {
    my $self = shift;
    return $self->dbic->dbh;
}

sub insert_connect {
    my ($self, $user_id, $provider_data) = @_;

    ## check if it's connected by someone else
    my $provider              = $provider_data->{user}->{identity}->{provider};
    my $provider_identity_uid = $provider_data->{user}->{identity}->{provider_identity_uid};

    my $connected_user_id = $self->get_user_id_by_connect($provider_data);
    if ($connected_user_id) {
        if ($connected_user_id != $user_id) {
            return {error => 'CONNECTED_BY_OTHER'};
        }
        $self->dbic->run(
            sub {
                $_->do("
            UPDATE users.binary_user_connects
            SET provider_data = ?, date=NOW()
            WHERE binary_user_id = ? AND provider = ?
        ", undef, encode_json($provider_data), $user_id, $provider);
            });
    } else {
        $self->dbic->run(
            sub {
                $_->do("
            INSERT INTO users.binary_user_connects
                (binary_user_id, provider, provider_identity_uid, provider_data)
            VALUES
                (?, ?, ?, ?)
        ", undef, $user_id, $provider, $provider_identity_uid, encode_json($provider_data));
            });
    }

    return {success => 1};
}

sub get_user_id_by_connect {
    my ($self, $provider_data) = @_;

    my $provider              = $provider_data->{user}->{identity}->{provider};
    my $provider_identity_uid = $provider_data->{user}->{identity}->{provider_identity_uid};

    return $self->dbic->run(
        sub {
            $_->selectrow_array("
        SELECT binary_user_id FROM users.binary_user_connects WHERE provider = ? AND provider_identity_uid = ?
    ", undef, $provider, $provider_identity_uid);
        });
}

sub get_connects_by_user_id {
    my ($self, $user_id) = @_;

    my @providers = $self->dbic->run(
        sub {
            my $sth = $_->prepare("SELECT provider FROM users.binary_user_connects WHERE binary_user_id = ?");
            $sth->execute($user_id);
            my @providers;
            while (my ($p) = $sth->fetchrow_array) {
                push @providers, $p;
            }
            return @providers;
        });

    return wantarray ? @providers : [@providers];
}

sub remove_connect {
    my ($self, $user_id, $provider) = @_;

    return $self->dbic->run(
        sub {
            $_->do("
        DELETE FROM users.binary_user_connects WHERE binary_user_id = ? AND provider = ?
    ", undef, $user_id, $provider);
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

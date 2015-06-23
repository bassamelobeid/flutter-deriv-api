package BOM::Platform::Transaction;

=head1 NAME

BOM::Platform::Transaction

=head1 DESCRIPTION

Base transaction class that will contain functionaliy & validation
common to all transactions i.e payment and contract

=cut

use Moose;
use BOM::Database::DataMapper::Client;

=head2 freeze_client

Locks the client for transaction, returns the status based
on sucess or failure to lock

=cut

sub freeze_client {
    my ($self, $loginid) = @_;

    my $client_data_mapper = BOM::Database::DataMapper::Client->new({
        client_loginid => $loginid,
    });

    if (!$client_data_mapper->lock_client_loginid()) {
        return;
    }

    return 1;
}

=head3 unfreeze_client

Unlocks the client lock for transaction and returns the status
accordingly

=cut

sub unfreeze_client {
    my ($self, $loginid) = @_;

    my $client_data_mapper = BOM::Database::DataMapper::Client->new({
        client_loginid => $loginid,
    });

    return $client_data_mapper->unlock_client_loginid();
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;

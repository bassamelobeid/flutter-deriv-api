package BOM::Event::Actions::Wallets;

use strict;
use warnings;

use BOM::User;
use BOM::User::WalletMigration;

no indirect;

=head1 NAME

BOM::Event::Actions::Wallets - event handlers for wallet events


=head2 wallet_migration_started

The event handler for wallet migration started event.

Arguments:

=over 4

=item * C<user_id> - The user id of the user whose wallet migration has started.

=back

=cut

sub wallet_migration_started {
    my $params = shift;

    my $user      = BOM::User->new(id => $params->{user_id});
    my $migration = BOM::User::WalletMigration->new(user => $user);

    $migration->process();

    return 1;
}

1;

package BOM::Event::Actions::Wallets;

use strict;
use warnings;

use BOM::User;
use BOM::User::WalletMigration;

use Future::AsyncAwait;
use Syntax::Keyword::Try;

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

async sub wallet_migration_started {
    my ($params, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

    try {
        my $user      = BOM::User->new(id => $params->{user_id});
        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => $params->{app_id});

        $migration->process();
    } catch ($e) {
        die sprintf("Error processing wallet migration for user %s: %s", $params->{user_id} // 'undef', $e);
    }

    return 1;
}

1;

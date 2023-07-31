package BOM::RPC::v3::Wallets;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use Syntax::Keyword::Try;
use BOM::RPC::Registry '-dsl';
use BOM::User::WalletMigration;
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize);

requires_auth('trading', 'wallet');

=head1 NAME

BOM::RPC::v3::Wallets - RPC methods for managing wallets

=head2 wallet_migration

The controller for managing wallet migration.

=cut

my %ERROR_MAP = do {
    # Show localize to `make i18n` here, so strings are picked up for translation.
    # Call localize again on the hash value to do the translation at runtime.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        MigrationAlreadyInProgress    => localize('Wallet migration is already in progress.'),
        MigrationAlreadyFinished      => localize('Wallet migration is already finished.'),
        MigrationNotFailed            => localize('Migration is not in failed state.'),
        UserIsNotEligibleForMigration => localize('Your account is not ready for wallet migration.'),
    );
};

=head2 wallet_migration

The controller is responsible for handling RPC requests related to managing wallet migration for a user.

=head3 Arguments:

=over 4

=item * C<action> - The action to perform. Valid values are C<state>, C<start> and C<reset>.

=back

=head3 Response:

=over 4

=item * C<state> - The state of the migration. Valid values are C<eligible>, C<in_progress>, C<finished> and C<failed>.

=item * C<account_list> - The list of accounts that will be migrated.(Only returned when C<state> is C<eligible>)

=back

=cut

rpc wallet_migration => sub {
    my ($client, $args) = shift->@{qw(client args)};
    my $action = $args->{wallet_migration};

    my $migration = BOM::User::WalletMigration->new(user => $client->user);
    try {
        if ($action eq 'state') {
            my $state = $migration->state;

            if ($state eq 'eligible') {
                return +{
                    state        => $state,
                    account_list => $migration->plan,
                };
            }

            return +{state => $state};
        } elsif ($action eq 'start') {
            $migration->start;
            return +{state => 'in_progress'};
        } elsif ($action eq 'reset') {
            $migration->reset;
            return +{state => $migration->state};
        }

        die "Unknown action for wallet migration: " . ($action // 'undef');
    } catch ($e) {
        my $error_code = (ref $e eq 'HASH') && $e->{error_code} // '';

        my $error_msg = $ERROR_MAP{$error_code};

        unless ($error_msg) {
            $log->warnf('Wallet migration got unexpected error for action %s: %s', $action, $e);
            die $e;
        }
        return BOM::RPC::v3::Utility::create_error({
            code              => $error_code,
            message_to_client => localize($error_msg),
        });
    }
};

1;

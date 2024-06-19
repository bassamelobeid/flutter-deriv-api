use strict;
use warnings;
use BOM::Event::Script::DocumentExpirationReminder;
use Future::AsyncAwait;

=head2 description 

A script that sends a track event document_expiring_soon to those clients
whose documents are about to expiry in 90 days and also have mt5 regulated accounts.

=cut

(
    async sub {
        my $script = BOM::Event::Script::DocumentExpirationReminder->new();
        await $script->run();
    })->()->get;

1;

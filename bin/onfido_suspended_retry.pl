use strict;
use warnings;
use BOM::Event::Script::OnfidoSuspendedRetry;
use Future::AsyncAwait;

=head2 description 

Retry mechanism for POI manual uploads during planned Onfido outages.

=cut

(
    async sub {
        my $script = BOM::Event::Script::OnfidoSuspendedRetry->new;
        await $script->run(100);
    })->()->get;

1;

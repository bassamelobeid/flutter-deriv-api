use strict;
use warnings;
use BOM::Event::Script::OnfidoRetry;
use Future::AsyncAwait;

=head2 description 

Retry mechanism for onfido checks that are stuck on pending.

=cut

my $limit = $ARGV[0];

(
    async sub {
        await BOM::Event::Script::OnfidoRetry->run({custom_limit => $limit});
    })->()->get;

1;

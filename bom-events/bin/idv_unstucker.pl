use strict;
use warnings;
use BOM::Event::Script::IDVUnstucker;
use Future::AsyncAwait;

=head2 description 

Unstuck IDV requests in the `pending` status.

=cut

my $limit = $ARGV[0];

(
    async sub {
        await BOM::Event::Script::IDVUnstucker->run({custom_limit => $limit});
    })->()->get;

1;

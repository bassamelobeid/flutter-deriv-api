use strict;
use warnings;
use BOM::Event::Script::NodeJSBridgeTest;
use Future::AsyncAwait;

=head2 description 

Test NodeJS bridge (Receiver flow).

=cut

(
    async sub {
        await BOM::Event::Script::NodeJSBridgeTest->run();
    })->()->get;

1;

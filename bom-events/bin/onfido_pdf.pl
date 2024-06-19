use strict;
use warnings;
use BOM::Event::Script::OnfidoPDF;
use Future::AsyncAwait;

=head2 description 

Onfido PDF downloader script.

=cut

(
    async sub {
        await BOM::Event::Script::OnfidoPDF->run();
    })->()->get;

1;

use strict;
use warnings;
use Test::More;
use Devel::Cycle;
use Mojo::WebSocketProxy::RequestLogger;
use Log::Any::Adapter 'DERIV',
    log_level => 'info',
    stderr    => 'json';

subtest 'Check for circular references' => sub {
    my $logger = Mojo::WebSocketProxy::RequestLogger->new();
    my $cycles = find_cycle($logger);
    if (ref($cycles) eq 'ARRAY') {
        is(scalar(@$cycles), 0, 'No circular references found');
    } else {
        pass('No circular references found');
    }
};

done_testing();

use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Deep;
use Test::Exception;

use BOM::Event::Script::NodeJSBridgeTest;

my @emissions;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->redefine(
    'emit' => sub {
        my ($event, $args) = @_;
        push @emissions,
            {
            type    => $event,
            details => $args
            };
    });

subtest 'Event is emmited' => sub {
    @emissions = ();

    BOM::Event::Script::NodeJSBridgeTest::run()->get();

    cmp_deeply [@emissions],
        [{
            type    => 'monolith_hello',
            details => 'Hello from perl monolith!'
        }
        ],
        'Expected emissions';
};

done_testing();

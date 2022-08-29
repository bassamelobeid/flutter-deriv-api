use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::MockObject;

use BOM::Event::Actions::CustomerIO;

subtest 'trigger broadcast' => sub {
    my @activations;
    my $mock_trigger = Test::MockObject->new;
    $mock_trigger->mock(activate => sub { shift; push @activations, [@_] });

    my @triggers;
    my $mock_api = Test::MockObject->new;
    $mock_api->mock(new_trigger => sub { shift; push @triggers, [@_]; $mock_trigger });

    my $mock_customerio = Test::MockModule->new('BOM::Event::Actions::CustomerIO');
    $mock_customerio->redefine('_instance' => sub { $mock_api });

    my $cio = BOM::Event::Actions::CustomerIO->new;
    $cio->trigger_broadcast_by_ids(1, [1, 2], {my_var => 'my val'})->get;

    cmp_deeply \@triggers, [[campaign_id => 1]], 'campaign_id';
    cmp_deeply \@activations,
        [[{
                ids    => [1, 2],
                my_var => 'my val'
            }]
        ],
        'activations';

    my @ids = (1 .. 10000);
    @activations = ();

    $cio->trigger_broadcast_by_ids(2, \@ids,)->get;

    is scalar @activations,                    2,    'more than 9999 ids split into 2 triggers';
    is scalar $activations[0]->[0]->{ids}->@*, 9999, 'first trigger has 9999 ids';
    is scalar $activations[1]->[0]->{ids}->@*, 1,    'second trigger has 1 id';
};

done_testing();

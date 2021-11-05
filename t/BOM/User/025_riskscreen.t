use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Future;
use List::Util qw(first);

use BOM::User::RiskScreen;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $user = BOM::User->create(
    email    => 'riskscreen@binary.com',
    password => "hello",
);
my $user_2 = BOM::User->create(
    email    => 'riskscreen2@binary.com',
    password => "hello",
);

subtest 'create riskscreen' => sub {
    my %args;
    like exception { BOM::User::RiskScreen->new() }, qr/binary_user_id is mandatory/, 'Error for missing user id';
    $args{binary_user_id} = 100;
    like exception { BOM::User::RiskScreen->new(%args) }, qr/interface_reference is mandatory/, 'Missing interface ref error';
    $args{interface_reference} = 'xyz';
    like exception { BOM::User::RiskScreen->new(%args) }, qr/status is mandatory/, 'Missing status error';
    $args{status} = 'xyz';
    like exception { BOM::User::RiskScreen->new(%args) }, qr/Status 'xyz' is invalid/, 'Invalid status error';
    $args{status} = 'active';
    like exception { BOM::User::RiskScreen->new(%args) }, qr/Invalid user id/, 'Invalid user id error';
};

subtest 'Save and retrieval' => sub {
    is undef, $user->risk_screen, 'There is no risk screen object';

    my %args = (
        binary_user_id      => $user->id,
        status              => 'active',
        interface_reference => 'abcd',
    );

    my $risk_screen;
    lives_ok { $risk_screen = BOM::User::RiskScreen->new(%args) } 'Risk screen object is created';

    isa_ok $risk_screen, 'BOM::User::RiskScreen', 'Object type is correct';
    is_deeply $risk_screen,
        {
        'binary_user_id'      => $user->id,
        'interface_reference' => 'abcd',
        'status'              => 'active',
        },
        'Object structure is correct';

    $risk_screen->save();
    is_deeply $user->risk_screen,
        {
        'binary_user_id'          => $user->id,
        'interface_reference'     => 'abcd',
        'status'                  => 'active',
        'client_entity_id'        => undef,
        'date_updated'            => undef,
        'match_potential_volume'  => undef,
        'match_discounted_volume' => undef,
        'match_flagged_volume'    => undef,
        'flags'                   => undef,
        },
        'Database content is correct';

    %args = (
        'binary_user_id'          => $user_2->id,
        'interface_reference'     => 'xyz',
        'status'                  => 'active',
        'client_entity_id'        => 1234,
        'date_updated'            => '2020-01-01',
        'match_potential_volume'  => 1,
        'match_discounted_volume' => 2,
        'match_flagged_volume'    => 3,
        'flags'                   => ['flag1', 'flag2'],
    );
    $risk_screen = BOM::User::RiskScreen->new(%args);
    $risk_screen->save(), $risk_screen, 'Risk screen object is saved and retrieved correctly';
};

subtest 'Find and update' => sub {
    my %args = (a => 123);
    like exception { BOM::User::RiskScreen->find(%args) }, qr/Search criteria is empty/, 'Correct error for invalid search fields';

    %args = (binary_user_id => $user->id);
    is_deeply [BOM::User::RiskScreen->find(%args)], [$user->risk_screen], 'Search by use id';

    %args = (client_entity_id => 1234);
    is_deeply [BOM::User::RiskScreen->find(%args)], [$user_2->risk_screen], 'Search by interface ref';

    %args = (status => 'active');
    is_deeply [BOM::User::RiskScreen->find(%args)], [$user->risk_screen, $user_2->risk_screen], 'Search by interface ref';

    %args = (status => 'requested');
    $user_2->set_risk_screen(%args);
    is_deeply $user_2->risk_screen,
        {
        'binary_user_id'          => $user_2->id,
        'interface_reference'     => 'xyz',
        'status'                  => 'requested',
        'client_entity_id'        => 1234,
        'date_updated'            => '2020-01-01',
        'match_potential_volume'  => 1,
        'match_discounted_volume' => 2,
        'match_flagged_volume'    => 3,
        'flags'                   => ['flag1', 'flag2'],
        };
    is_deeply [BOM::User::RiskScreen->find(%args)], [$user_2->risk_screen], 'Search by the new status';

    %args = (
        'interface_reference'     => 'new interface id',
        'status'                  => 'disabled',
        'client_entity_id'        => 111111,
        'date_updated'            => '2020-06-07',
        'match_potential_volume'  => 10,
        'match_discounted_volume' => 20,
        'match_flagged_volume'    => 30,
        'flags'                   => undef,
    );
    $user_2->set_risk_screen(%args);
    is_deeply $user_2->risk_screen, {%args, binary_user_id => $user_2->id}, 'risk screen is updated and retrived correctly';
};

done_testing();

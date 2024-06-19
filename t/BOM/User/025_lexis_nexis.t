use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Future;
use List::Util qw(first);

use BOM::User::LexisNexis;

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
    like exception { BOM::User::LexisNexis->new() }, qr/binary_user_id is mandatory/, 'Error for missing user id';
    $args{binary_user_id} = 100;
    like exception { BOM::User::LexisNexis->new(%args) }, qr/client_loginid is mandatory/, 'Missing client_loginid error';
    $args{client_loginid} = 'xyz';
    like exception { BOM::User::LexisNexis->new(%args) }, qr/alert_status is mandatory/, 'Missing alert_status error';
    $args{alert_status} = 'xyz';
    like exception { BOM::User::LexisNexis->new(%args) }, qr/alert_status 'xyz' is invalid/, 'Invalid alert_status error';
    $args{alert_status} = 'open';
    like exception { BOM::User::LexisNexis->new(%args) }, qr/Invalid user id/, 'Invalid user id error';
    $args{binary_user_id} = $user->id;
    $args{note}           = 'abcd';
    like exception { BOM::User::LexisNexis->new(%args) }, qr/Invalid screening reason .* abcd/, 'Invalid screening reason error';
};

subtest 'Save and retrieval' => sub {
    is undef, $user->lexis_nexis, 'There is no lexis_nexis object';

    my %args = (
        binary_user_id => $user->id,
        alert_status   => 'open',
        client_loginid => 'abcd',
        alert_id       => 2000001
    );

    my $lexis_nexis;
    lives_ok { $lexis_nexis = BOM::User::LexisNexis->new(%args) } 'lexis nexis object is created';

    isa_ok $lexis_nexis, 'BOM::User::LexisNexis', 'Object type is correct';
    is_deeply $lexis_nexis,
        {
        'binary_user_id' => $user->id,
        'client_loginid' => 'abcd',
        'alert_status'   => 'open',
        'alert_id'       => 2000001
        },
        'Object structure is correct';

    $lexis_nexis->save();
    is_deeply $user->lexis_nexis,
        {
        'binary_user_id' => $user->id,
        'client_loginid' => 'abcd',
        'alert_status'   => 'open',
        'alert_id'       => 2000001,
        'date_updated'   => undef,
        'note'           => undef,
        'date_added'     => undef
        },
        'Database content is correct';

    %args = (
        'binary_user_id' => $user_2->id,
        'client_loginid' => 'xyz',
        'alert_status'   => 'open',
        'alert_id'       => 1234,
        'date_updated'   => '2020-01-01',
        'note'           => 'Affiliate',
        'date_added'     => '2019-09-09'
    );
    $lexis_nexis = BOM::User::LexisNexis->new(%args);
    $lexis_nexis->save(), $lexis_nexis, 'lexis nexis object is saved and retrieved correctly';
};

subtest 'Find and update' => sub {
    my %args = (a => 123);
    like exception { BOM::User::LexisNexis->find(%args) }, qr/Search criteria is empty/, 'Correct error for invalid search fields';

    %args = (binary_user_id => $user->id);
    is_deeply [BOM::User::LexisNexis->find(%args)], [$user->lexis_nexis], 'Search by use id';
};

done_testing();

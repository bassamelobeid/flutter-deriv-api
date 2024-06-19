use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use UUID::Tiny;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../../../lib";

use BOM::Service;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use UserServiceTestHelper;

my $user    = UserServiceTestHelper::create_user('frieren@strahl.com');
my $context = UserServiceTestHelper::create_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'user resident, check update fails' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            residence => 'AA',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',     'call failed';
    is $response->{class},  'Immutable', 'Immutable attribute error class';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(residence)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                'ok', 'readback call succeeded';
    is $response->{attributes}{residence}, 'aq', 'residence is unchanged';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_force',
        user_id    => $user->id,
        attributes => {
            residence => 'AA',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [qw(residence)], 'affected array is correct';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(residence)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                'ok', 'readback call succeeded';
    is $response->{attributes}{residence}, 'AA', 'residence updated value returned';

};

done_testing();

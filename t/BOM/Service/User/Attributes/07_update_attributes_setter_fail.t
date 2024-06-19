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
my $context = UserServiceTestHelper::create_context($user);

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'user email attributes, update fails but values unchanged' => sub {
    # We will keep correlation id for duration of test, we want to make sure that cache
    # is not polluted by changes
    $context->{correlation_id} = BOM::Service::random_uuid();

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name email preferred_language)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    my $original_values = $response->{attributes};

    # We have a mix of client and user variables here so its possible for client to save
    # correctly but not user, validation should stop either being persisted
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            first_name         => 'BLAHBLAHBLAH',
            email              => 'someone@somewhere.com',
            preferred_language => 'BADFIELD',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'call failed on language as expected';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name email preferred_language)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    is_deeply $original_values, $response->{attributes}, 'original values unchanged after failed update';
};

done_testing();

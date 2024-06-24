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
my $context = UserServiceTestHelper::get_user_service_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'user phone_number_verified 0->1' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {phone_number_verified => 0});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'initialise to false';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(phone_number_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                              'ok', 'readback ok';
    is $response->{attributes}->{phone_number_verified}, 0,    'is false value';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {phone_number_verified => 1});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update call succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(phone_number_verified)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(phone_number_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                              'ok', 'readback ok';
    is $response->{attributes}->{phone_number_verified}, 1,    'is true value';
};

subtest 'user phone_number_verified 1->0' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {phone_number_verified => 1});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'initialise to true';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(phone_number_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                              'ok', 'readback ok';
    is $response->{attributes}->{phone_number_verified}, 1,    'is true value';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {phone_number_verified => 0});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update call succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(phone_number_verified)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(phone_number_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                              'ok', 'readback ok';
    is $response->{attributes}->{phone_number_verified}, 0,    'is false value';
};

done_testing();

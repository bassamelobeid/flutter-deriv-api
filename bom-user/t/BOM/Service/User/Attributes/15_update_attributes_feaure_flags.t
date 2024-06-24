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

subtest 'user feature_flag checks' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(feature_flag)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    my $expected_result = {
        wallet => 0,
    };
    is_deeply $response->{attributes}{feature_flag}, $expected_result, 'Default wallet is present in get';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {feature_flag => {wallet => 1}});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'add new flags, set wallet to true';
    is_deeply [sort @{$response->{affected}}], [sort qw(feature_flag)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(feature_flag)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    $expected_result = {wallet => 1};
    is_deeply $response->{attributes}{feature_flag}, $expected_result, 'Updated flags are as expected';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {feature_flag => {wallet => 0}});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update call succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(feature_flag)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(feature_flag)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    $expected_result = {wallet => 0};
    is_deeply $response->{attributes}{feature_flag}, $expected_result, 'Updated flags are as expected';
};

done_testing();

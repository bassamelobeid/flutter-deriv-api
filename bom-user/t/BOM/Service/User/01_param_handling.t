use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
use UUID::Tiny;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

use BOM::Service;
use BOM::Service::Helpers;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use UserServiceTestHelper;

my $user    = UserServiceTestHelper::create_user('frieren@strahl.com');
my $context = UserServiceTestHelper::get_user_service_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'missing context' => sub {
    my $response = BOM::Service::user(
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'missing correlation_id' => sub {
    my $response = BOM::Service::user(
        context    => {auth_token => 'Test Token, just for testing'},
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'missing user_id' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'missing command' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'invalid command' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'this_command_does_not_exist',
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'junk in the request' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        irrelevant => 'junk',
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'read via int user_id' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is $response->{attributes}{first_name},     'Frieren',            'first_name ok';
    is $response->{attributes}{email},          'frieren@strahl.com', 'email ok';
    is scalar(keys %{$response->{attributes}}), 2,                    'only two attributes returned';
};

subtest 'read via uuid user_id' => sub {
    # Stop the booby traps going off!!
    my $mock = Test::MockModule->new('CORE::GLOBAL');
    $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => BOM::Service::Helpers::binary_user_id_to_uuid($user->id),
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is $response->{attributes}{first_name},     'Frieren',            'first_name ok';
    is $response->{attributes}{email},          'frieren@strahl.com', 'email ok';
    is scalar(keys %{$response->{attributes}}), 2,                    'only two attributes returned';

    $mock->unmock('caller');
};

subtest 'read via email user_id' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 'frieren@strahl.com',
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is $response->{attributes}{first_name},     'Frieren',            'first_name ok';
    is $response->{attributes}{email},          'frieren@strahl.com', 'email ok';
    is scalar(keys %{$response->{attributes}}), 2,                    'only two attributes returned';
};

subtest 'non-existent user by user_id' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 123456789,
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'non-existent user by uuid' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'non-existent user by email' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 'non@existant.email.com',
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'non-existent user by email' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 'non@existant.email.com',
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'error messages have line numbers and stack trace, message does not' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 'non@existant.email.com',
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    like $response->{error},     qr /.+ at .+ line .+/, 'error detail returned has at ... line...';
    unlike $response->{message}, qr /.+ at .+ line .+/, 'error message returned has no stack trace';
};

subtest 'prod error messages have error detail' => sub {

    my $mock_prod = Test::MockModule->new('BOM::Config');
    $mock_prod->mock('on_production', sub { 1 });

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => 'non@existant.email.com',
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    unlike $response->{message}, qr /.+ at .+ line .+/, 'error message returned has no stack trace';
    ok !$response->{error}, 'error detail not returned';

    $mock_prod->unmock('on_production');
};

done_testing();

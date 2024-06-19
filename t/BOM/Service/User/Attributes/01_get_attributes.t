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

subtest 'get mix of user and client attributes' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name last_name email email_verified )],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is $response->{attributes}{first_name},     'Frieren',            'first_name ok';
    is $response->{attributes}{last_name},      'Elf',                'last_name ok';
    is $response->{attributes}{email},          'frieren@strahl.com', 'email ok';
    is $response->{attributes}{email_verified}, 1,                    'email_verified ok';
    is scalar(keys %{$response->{attributes}}), 4,                    'only four attributes returned';
};

subtest 'invalid attribute' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name fake_attribute last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'no attributes' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'missing attributes' => sub {
    my $response = BOM::Service::user(
        context => $context,
        command => 'get_attributes',
        user_id => $user->id,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'invalid attributes type string' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => 'first_name',
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'invalid attributes type hash' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => {first_name => 'hello'},
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'bool-nullable return check' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(fatca_declaration)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                        'ok',  'call succeeded';
    is $response->{attributes}{fatca_declaration}, undef, 'undefined value returned';
};

done_testing();

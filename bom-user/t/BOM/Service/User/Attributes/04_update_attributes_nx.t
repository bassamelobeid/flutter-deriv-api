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

subtest 'user preferred_language, check update not existing' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_nx',
        user_id    => $user->id,
        attributes => {
            preferred_language => 'AB_CD',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [qw(preferred_language)], 'affected array contains preferred_language';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                         'ok',    'readback call succeeded';
    is $response->{attributes}{preferred_language}, 'AB_CD', 'preferred_language is correct';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_nx',
        user_id    => $user->id,
        attributes => {
            preferred_language => 'EF_GH',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [], 'affected array is empty';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                         'ok',    'readback call succeeded';
    is $response->{attributes}{preferred_language}, 'AB_CD', 'preferred_language unchanged';

};

subtest 'user fatca_declaration, check update not existing' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_nx',
        user_id    => $user->id,
        attributes => {
            fatca_declaration => 0,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [qw(fatca_declaration)], 'affected array contains fatca_declaration';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(fatca_declaration)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                        'ok', 'readback call succeeded';
    is $response->{attributes}{fatca_declaration}, 0,    'fatca_declaration is correct';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_nx',
        user_id    => $user->id,
        attributes => {
            fatca_declaration => 1,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [], 'affected array is empty';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(fatca_declaration)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                        'ok', 'readback call succeeded';
    is $response->{attributes}{fatca_declaration}, 0,    'fatca_declaration unchanged';

};

done_testing();

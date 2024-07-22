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

subtest 'changing languages' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok',  'request succeeded';
    is $response->{attributes}->{preferred_language}, undef, 'preferred language is not defined';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'ZH_CN'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok',    'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZH_CN', 'preferred language is ZH_CN';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'fa'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'FA', 'preferred language is FA';
};

subtest 'changing languages failure cases' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'ZA'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => ''});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'request failed for empty string';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZA', 'preferred language is still ZA';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'a'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'request failed for single char';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZA', 'preferred language is still ZA';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'AS '});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'request failed for whitespace';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZA', 'preferred language is still ZA';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'AD_SDD'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'request failed for too many characters';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZA', 'preferred language is still ZA';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'ZH-CN'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'request failed for bad format';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'ZA', 'preferred language is still ZA';
};

subtest 'changing languages same context' => sub {

    $context->{correlation_id} = BOM::Service::random_uuid();

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'EN'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'EN', 'preferred language is EN defined';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'RU'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'RU', 'preferred language is RU defined';
};

subtest 'changing languages different context' => sub {

    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'EN'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'EN', 'preferred language is EN defined';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {preferred_language => 'RU'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'request succeeded';
    is_deeply [sort @{$response->{affected}}], [sort qw(preferred_language)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email preferred_language)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                           'ok', 'request succeeded';
    is $response->{attributes}->{preferred_language}, 'RU', 'preferred language is RU defined';
};

done_testing();

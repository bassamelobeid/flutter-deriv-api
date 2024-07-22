use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
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

# Redefine some of the oath mocks to verify what is written to the database
my $mock = Test::MockModule->new("BOM::Database::Model::OAuth");
my $oauth_loginid;
my $oauth_fingerprint;
my $oauth_user_id;

$mock->redefine(
    'revoke_tokens_by_loignid_and_ua_fingerprint',
    sub {
        my ($self, $p_loginid, $p_ua_fingerprint) = @_;
        $oauth_loginid     = $p_loginid;
        $oauth_fingerprint = $p_ua_fingerprint;
        return 1;
    });

$mock->redefine(
    'revoke_refresh_tokens_by_user_id',
    sub {
        my ($self, $p_user_id) = @_;
        $oauth_user_id = $p_user_id;
        return 1;
    });

subtest 'set flags and readback' => sub {
    $oauth_loginid     = undef;
    $oauth_fingerprint = undef;
    $oauth_user_id     = undef;

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            is_totp_enabled => 1,
            secret_key      => 'Secret1',
            ua_fingerprint  => 'fingerprint'
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(is_totp_enabled secret_key)], 'affected array contains expected attributes';
    is $oauth_user_id,     $user->id,                            'user_id written as expected';
    is $oauth_loginid,     $user->get_default_client()->loginid, 'loginid written as expected';
    is $oauth_fingerprint, 'fingerprint',                        'fingerprint written as expected';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(is_totp_enabled secret_key)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    my $expected_result = {
        is_totp_enabled => 1,
        secret_key      => 'Secret1'
    };
    is_deeply $response->{attributes}, $expected_result, 'Updated flags are as expected';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(ua_fingerprint)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'readback failed on ua_fingerprint ';

    $oauth_loginid             = undef;
    $oauth_fingerprint         = undef;
    $oauth_user_id             = undef;
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response                  = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            is_totp_enabled => 0,
            secret_key      => 'Secret2',
            ua_fingerprint  => 'fingerprint'
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(is_totp_enabled secret_key)], 'affected array contains expected attributes';
    is $oauth_user_id,     $user->id,                            'user_id written as expected';
    is $oauth_loginid,     $user->get_default_client()->loginid, 'loginid written as expected';
    is $oauth_fingerprint, 'fingerprint',                        'fingerprint written as expected';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(is_totp_enabled secret_key)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    $expected_result = {
        is_totp_enabled => 0,
        secret_key      => 'Secret2'
    };
    is_deeply $response->{attributes}, $expected_result, 'Updated flags are as expected';
};

subtest 'no change update does not write or clear tokens' => sub {
    $oauth_loginid     = undef;
    $oauth_fingerprint = undef;
    $oauth_user_id     = undef;

    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {is_totp_enabled => 0});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update ok';
    is_deeply [sort @{$response->{affected}}], [], 'affected array contains expected attributes';

    is $oauth_user_id,     undef, 'user_id undef as expected';
    is $oauth_loginid,     undef, 'loginid undef as expected';
    is $oauth_fingerprint, undef, 'fingerprint undef as expected';
};

subtest 'enable clears tokens, does not change secret key' => sub {
    $oauth_loginid     = undef;
    $oauth_fingerprint = undef;
    $oauth_user_id     = undef;

    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            is_totp_enabled => 1,
            ,
            secret_key     => 'Secret3',
            ua_fingerprint => 'fingerprint'
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(is_totp_enabled secret_key)], 'affected array contains expected attributes';
    is $oauth_user_id,     $user->id,                            'user_id written as expected';
    is $oauth_loginid,     $user->get_default_client()->loginid, 'loginid written as expected';
    is $oauth_fingerprint, 'fingerprint',                        'fingerprint written as expected';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(is_totp_enabled secret_key)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'readback ok';
    my $expected_result = {
        is_totp_enabled => 1,
        secret_key      => 'Secret3'
    };
    is_deeply $response->{attributes}, $expected_result, 'Updated flags are as expected';

    $oauth_loginid             = undef;
    $oauth_fingerprint         = undef;
    $oauth_user_id             = undef;
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response                  = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {is_totp_enabled => 1});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update ok';
    is_deeply [sort @{$response->{affected}}], [], 'affected array contains expected attributes';
    is $oauth_user_id,     undef, 'user_id undef as expected';
    is $oauth_loginid,     undef, 'loginid undef as expected';
    is $oauth_fingerprint, undef, 'fingerprint undef as expected';
};

$mock->unmock_all();

done_testing();

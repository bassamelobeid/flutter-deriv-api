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

my $email   = 'frieren@strahl.com';
my $user    = UserServiceTestHelper::create_user($email);
my $context = UserServiceTestHelper::get_user_service_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'Check all 3 email fields can be read/written' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email email_consent email_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                       'ok',   'update call succeeded';
    is $response->{attributes}->{email},          $email, 'email is correct';
    is $response->{attributes}->{email_consent},  1,      'email_consent is correct';
    is $response->{attributes}->{email_verified}, 1,      'email_verified is correct';

    # New correlation id for each call means we get an uncached response
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            email          => 'shiny@new.email.com',
            email_consent  => 1,
            email_verified => 0
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update all vars';
    is_deeply [sort @{$response->{affected}}], [sort qw(email email_verified)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email email_consent email_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                       'ok',                  'update call succeeded';
    is $response->{attributes}->{email},          'shiny@new.email.com', 'updated email is correct';
    is $response->{attributes}->{email_consent},  1,                     'email_consent is correct';
    is $response->{attributes}->{email_verified}, 0,                     'email_verified is correct';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            email          => 'shiny@new.email.com',
            email_consent  => 0,
            email_verified => 0
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update email_consent';
    is_deeply [sort @{$response->{affected}}], [sort qw(email_consent)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email email_consent email_verified)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                       'ok',                  'update call succeeded';
    is $response->{attributes}->{email},          'shiny@new.email.com', 'updated email is correct';
    is $response->{attributes}->{email_consent},  0,                     'email_consent is correct';
    is $response->{attributes}->{email_verified}, 0,                     'email_verified is correct';
};

done_testing();

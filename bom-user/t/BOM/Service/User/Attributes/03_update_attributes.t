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

subtest 'user email attributes, no change equals no write' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            email          => 'frieren@strahl.com',
            email_verified => 1,
            email_consent  => 1,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [], 'affected array contains no changed attributes';
};

subtest 'user email attributes' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            email          => 'new@email.com',
            email_verified => 0,
            email_consent  => 0,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(email email_consent email_verified)], 'affected array contains expected attributes';

    # Now read back the values and check they are as expected, different correlation_id
    # to ensure we are not just reading from the cache
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(email email_verified email_consent)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                     'ok',            'readback call succeeded';
    is $response->{attributes}{email},          'new@email.com', 'updated email is correct';
    is $response->{attributes}{email_verified}, 0,               'updated email_verified is correct';
    is $response->{attributes}{email_consent},  0,               'updated email_consent is correct';
};

subtest 'user trading password attributes' => sub {
    # Read the old one first, we going to compare the crypt output to see if changed
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $original_passwords = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(dx_trading_password trading_password)],
    )->{attributes};

    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            dx_trading_password => '1.Look, a new password!!',
            trading_password    => '2.Look, a new password!!'
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(dx_trading_password trading_password)], 'affected array contains expected attributes';

    # Now read back the values and check they are as expected, different correlation_id
    # to ensure we are not just reading from the cache
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(dx_trading_password trading_password)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                            'ok',                                       'readback call succeeded';
    isnt $response->{attributes}{dx_trading_password}, $original_passwords->{dx_trading_password}, 'dx_trading_password has changed';
    isnt $response->{attributes}{trading_password},    $original_passwords->{trading_password},    'trading_password has changed';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            trading_password => undef,
        });
    is $response->{status}, 'error', 'call failed, passwords cannot be set to undef';
    ok $response->{message}, 'no message returned';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            dx_trading_password => undef,
        });
    is $response->{status}, 'error', 'call failed, passwords cannot be set to undef';
    ok $response->{message}, 'no message returned';
};

subtest 'client attributes check' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            first_name => 'Check 001',
            last_name  => 'Check 002',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(first_name last_name)], 'affected array contains expected attributes';

    # Read back and check
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name last_name)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                 'ok',        'readback call succeeded';
    is $response->{attributes}{first_name}, 'Check 001', 'first_name is correct';
    is $response->{attributes}{last_name},  'Check 002', 'last_name is correct';
};

subtest 'set mix of user and client attributes' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            first_name => 'Mix 001',
            email      => 'mix@mix.mix',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(first_name email)], 'affected array contains expected attributes';

    # Read back and check
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name email)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                 'ok',          'readback call succeeded';
    is $response->{attributes}{email},      'mix@mix.mix', 'email is correct';
    is $response->{attributes}{first_name}, 'Mix 001',     'first_name is correct';
};

subtest 'invalid attribute' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {
            first_name     => 'New first name',
            fake_attribute => 'Something',
            last_name      => 'New last name',
        },
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'no attributes' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {},
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'missing attributes' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context => $context,
        command => 'update_attributes',
        user_id => $user->id,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'invalid attributes type string' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => 'first_name',
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

subtest 'invalid attributes type hash' => sub {
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => ['first_name', 'hello'],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'error message returned';
};

done_testing();

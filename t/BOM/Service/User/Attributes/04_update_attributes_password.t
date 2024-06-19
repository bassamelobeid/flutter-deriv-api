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

my $dump_response    = 0;
my $default_password = 'A new password 1234 !!';

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'user password flag checks' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password          => 'Look, a new password!!'},
        flags      => {password_previous => undef});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'call failed, password reason must be provided';
    ok $response->{message}, 'error message returned';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'Look, a new password!!'},
        flags      => {
            password_update_reason => 'junk',
            password_previous      => undef
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'call failed, must be a specific string';
    ok $response->{message}, 'error message returned';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'A new password 5678 !!'},
        flags      => {
            password_update_reason => 'reset_password',
            password_previous      => undef,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(password)], 'affected array contains expected attributes';

    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => $default_password},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => undef
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(password)], 'affected array contains expected attributes';
};

subtest 'user password changes and token erase' => sub {
    # Make a new user to ensure tokens are in place
    my $alt_user = UserServiceTestHelper::create_user('frieren2@strahl.com');

    my $oauth = BOM::Database::Model::OAuth->new;
    ok $oauth->has_other_login_sessions($alt_user->get_default_client()->loginid), 'There are open login sessions';
    my $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($alt_user->id);
    is scalar $refresh_tokens->@*, scalar @UserServiceTestHelper::app_ids, 'refresh tokens have been generated correctly';

    # Read the old one first, we going to compare the crypt output to see if changed
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $original_passwords = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $alt_user->id,
        attributes => [qw(password)],
    )->{attributes};

    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $alt_user->id,
        attributes => {password => 'A new password 1234 !!'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => undef
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';
    is_deeply [sort @{$response->{affected}}], [sort qw(password)], 'affected array contains expected attributes';

    # Now check the tokens are gone
    $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($alt_user->id);
    is scalar $refresh_tokens->@*, 0, 'refresh tokens have been revoked correctly';
    ok !$oauth->has_other_login_sessions($alt_user->get_default_client()->loginid), 'User access tokens are revoked';

    # Now read back the values and check they are as expected, different correlation_id
    # to ensure we are not just reading from the cache
    $context->{correlation_id} = BOM::Service::random_uuid();
    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $alt_user->id,
        attributes => [qw(password)],
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                 'ok',                            'readback call succeeded';
    isnt $response->{attributes}{password}, $original_passwords->{password}, 'password has changed';

};

subtest 'user password to empty check' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => undef},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => undef
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error', 'call failed, passwords cannot be set to undef';
    ok $response->{message}, 'error message returned';
};

subtest 'That password is incorrect. Please try again' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'new_password'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => 'old_password',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, password is incorrect';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/That password is incorrect. Please try again.+/, 'correct error message returned';
};

subtest 'Current password and new password cannot be the same' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'A new password 1234 !!'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => 'A new password 1234 !!',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, old password cannot be same as new';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Current password and new password cannot be the same.+/, 'correct error message returned';
};

subtest 'Your password must be 8 to 25 characters long, no special' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'unsuitable'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => 'A new password 1234 !!',
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, no special';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Your password must be 8 to 25 characters long.+/, 'correct error message returned';
};

subtest 'Your password must be 8 to 25 characters long, no number' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'New#_p$ssword'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => $default_password,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, no number';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Your password must be 8 to 25 characters long.+/, 'correct error message returned';
};

subtest 'Your password must be 8 to 25 characters long, too short' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'pa$5A'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => $default_password,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, to short';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Your password must be 8 to 25 characters long.+/, 'correct error message returned';
};

subtest 'Your password must be 8 to 25 characters long, no upper case' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'pass$5ss'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => $default_password,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, no upper case';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Your password must be 8 to 25 characters long.+/, 'correct error message returned';
};

subtest 'Your password must be 8 to 25 characters long, no lower case' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'PASS$5SS'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => $default_password,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, no lower case';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/Your password must be 8 to 25 characters long.+/, 'correct error message returned';
};

subtest 'You cannot use your email address as your password' => sub {
    # Now try and wipe the passwords, should fail
    $context->{correlation_id} = BOM::Service::random_uuid();
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {password => 'FRIEREN@strahl.com'},
        flags      => {
            password_update_reason => 'change_password',
            password_previous      => $default_password,
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'error',         'call failed, new password not suitable, email as password';
    is $response->{class},  'PasswordError', 'error class is correct';
    like $response->{message}, qr/You cannot use your email address as your password.+/, 'correct error message returned';
};

done_testing();

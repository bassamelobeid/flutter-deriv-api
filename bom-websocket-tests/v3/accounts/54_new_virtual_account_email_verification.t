use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Platform::Token;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

use Guard;
use await;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# We don't want to fail due to hitting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

## do not send email
use Test::MockObject;
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

subtest 'create virtual account without email verification' => sub {
    my $email     = 'suspended_email_verification@deriv.com';
    my $create_vr = {
        new_account_virtual => 1,
        client_password     => 'Abcd1234!',
        residence           => 'de',
        email_consent       => 1,
        email               => $email
    };

    $app_config->set({'email_verification.suspend.virtual_accounts' => 1});
    ok(BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts, 'optional email verification signup is enabled');

    my $t   = build_wsapi_test();
    my $res = $t->await::new_account_virtual($create_vr);

    is($res->{msg_type}, 'new_account_virtual');
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');

    my $user = BOM::User->new(email => $email);
    ok $user->email_consent, 'Email consent flag set';

    ok !$user->email_verified, 'User is not email verified';

    $app_config->set({'email_verification.suspend.virtual_accounts' => 0});
    $t->finish_ok;
};

done_testing;

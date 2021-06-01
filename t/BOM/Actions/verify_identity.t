use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use HTTP::Response;
use JSON::MaybeUTF8 qw( encode_json_utf8 );

use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# Initiate test client
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $email = $test_client->email;
my $user  = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);

my $mock_http = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(POST => undef);    # prevent making real calls

my $mock_country_configs = Test::MockModule->new('Brands::Countries');
$mock_country_configs->mock(is_idv_supported => 1);

subtest 'Verify identity - Smile Identity provider' => sub {
    my $verification_status = 'Verified';

    $mock_http->mock(
        POST => sub {
            my (undef, $url) = @_;

            my $res = HTTP::Response->new(
                200, undef, undef,
                encode_json_utf8({
                        Actions => {
                            Verify_ID_Number     => $verification_status,
                            Return_Personal_Info => 'Not Returned'
                        }}));

            return Future->done($res);
        });

    $test_client->residence('ke');
    $test_client->save();

    my $event_handler = BOM::Event::Process::get_action_mappings()->{identity_verification_requested};

    note 'Verified status';
    my $args = {
        loginid     => $test_client->loginid,
        test_result => 0
    };

    like warning { $event_handler->($args)->get }, qr/Identity is verified./i, 'Identity verification status is verified';

    note 'Not verified status';
    $verification_status = 'Not Verified';
    like warning { $event_handler->($args)->get }, qr/Identity is not verified./i, 'Identity verification status is NOT verified';

    note 'N/A status';
    $verification_status = 'N/A';
    like warning { $event_handler->($args)->get }, qr/Identity is unknown./i, 'Identity verification status is unknown';

    note 'Unavailable service status';
    $verification_status = 'Issuer Unavailable';
    like warning { $event_handler->($args)->get }, qr/Identity is unknown./i, 'Identity verification status is unknown';
};

done_testing();

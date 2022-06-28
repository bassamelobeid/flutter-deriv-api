use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;

use Date::Utility;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::User::IdentityVerification;

# Initiate test client
my $email = 'testw@binary.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => "pwd",
    email_verified => 1,
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$user->add_client($client);

my @requests;
my ($resp, $args) = undef;
my $updates = 0;

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
my $mock_idv_status;
$mock_idv_model->redefine(
    update_document_check => sub {
        $updates++;
        my ($idv, $args) = @_;
        $mock_idv_status = $args->{status};
        return $mock_idv_model->original('update_document_check')->(@_);
    });

my $mock_http = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(
    POST => sub {
        push @requests, $_[2];    # request body

        return $resp->() if ref $resp eq 'CODE';
        return $resp;
    });                                # prevent making real calls

my $mock_country_configs = Test::MockModule->new('Brands::Countries');
$mock_country_configs->mock(
    is_idv_supported => sub {
        my (undef, $country) = @_;

        return 0 if $country eq 'id';
        return 1;
    });

my $mock_config_service = Test::MockModule->new('BOM::Config::Services');
$mock_config_service->mock(
    config => +{
        host => 'dummy',
        port => '8080',
    });

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

my $mock_idv_event_action = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');

subtest 'microservice only provider' => sub {
    $mock_idv_event_action->mock('_is_microservice_available', 0);

    $args = {
        loginid => $client->loginid,
    };

    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'zw',
        number          => '12345678A00',
        type            => 'national_id'
    });

    $client->first_name('Juan');
    $client->last_name('Deez');
    $client->date_of_birth('1989-01-30');
    $client->save();

    $client->status->setnx('poi_name_mismatch', 'test', 'test');
    $client->status->clear_age_verification;

    like(
        exception {
            $idv_event_handler->($args)->get
        },
        qr/Could not trigger IDV, the function for provider derivative_wealth not found/,
        'we do not have a perl implementation for this provider'
    );

    is $updates, 0, 'no updates whatsover';
    ok !@requests, 'No request was made';

    ok $client->status->poi_name_mismatch, 'poi_name_mismatch is not removed';
    ok !$client->status->age_verification, 'age verified not set';
};

subtest 'verify identity by derivative_wealth through microservice is passed and data are valid' => sub {
    $mock_idv_event_action->mock('_is_microservice_available', 1);

    $args = {
        loginid => $client->loginid,
    };

    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'zw',
        number          => '12345678A00',
        type            => 'national_id'
    });

    $client->first_name('Juan');
    $client->last_name('Deez');
    $client->date_of_birth('1989-01-30');
    $client->save();

    $client->status->setnx('poi_name_mismatch', 'test', 'test');
    $client->status->clear_age_verification;

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status        => 'pass',
                    request_body  => {request => 'sent'},
                    response_body => {
                        firstName   => 'Juan',
                        surname     => 'Deez',
                        dateOfBirth => '1989-01-30',
                    },
                })));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    cmp_deeply decode_json_utf8($requests[0]),
        {
        document => {
            issuing_country => 'zw',
            type            => 'national_id',
            number          => '12345678A00',
        },
        profile => {
            login_id   => $client->loginid,
            first_name => 'Juan',
            last_name  => 'Deez',
            birthdate  => '1989-01-30',
        },
        address => {
            line_1    => $client->address_line_1,
            line_2    => $client->address_line_2,
            postcode  => $client->address_postcode,
            residence => $client->residence,
        }
        },
        'request body is correct';
    is $updates, 2, 'update document triggered twice correctly';

    $client = BOM::User::Client->new({loginid => $client->loginid});
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification, 'age verified correctly';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
};

subtest 'microservice is unavailable' => sub {
    $resp = Future->done(HTTP::Response->new(200, undef, undef, undef));

    $idv_model->add_document({
        issuing_country => 'zw',
        number          => '12345678A00',
        type            => 'national_id'
    });

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $doc  = $idv_model->get_last_updated_document();
    my $msgs = decode_json_utf8 $doc->{status_messages};

    is_deeply $msgs, ['UNAVAILABLE_MICROSERVICE'], 'message is correct';
};

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

$mock_idv_event_action->unmock_all;

done_testing();

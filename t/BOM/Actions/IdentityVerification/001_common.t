use strict;
use warnings;
no indirect;

use Test::Fatal;
use Test::More;

use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;

# Initiate test client
my $email = 'test1@binary.com';
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

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

my $args = {
    loginid => $client->loginid,
};

subtest 'verify identity basic' => sub {
    $args = {loginid => 'CR0'};
    like exception { $idv_event_handler->($args)->get }, qr/Could not instantiate client/i, 'Exception thrown for unknown client';

    $args = {
        loginid => $client->loginid,
    };

    like exception { $idv_event_handler->($args)->get }, qr/No standby document found/i, 'Exception thrown for user without standby document for IDV';

    $idv_model->add_document({
        issuing_country => 'id',
        number          => '123',
        type            => 'national_id'
    });
    is $idv_event_handler->($args)->get, undef, 'document issuing country not supported by IDV, event returned without processing';
};

done_testing();


use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::User::Client;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $mocked_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $uploaded;

$mocked_documents->mock(
    'uploaded',
    sub {
        my $self = shift;
        $self->_clear_uploaded;
        return $uploaded;
    });

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email          => 'pow-1@email.com',
    password       => BOM::User::Password::hashpw('asdf12345'),
    email_verified => 1,
);
subtest 'no edd status' => sub {

    $user->add_client($test_client_cr);
    $uploaded = {};

    ok !$test_client_cr->needs_pow_verification, 'POW is not needed';
};

subtest 'no edd status with documnet upload' => sub {

    $user->add_client($test_client_cr);

    $uploaded = {
        proof_of_income => {
            documents   => 'something',
            is_uploaded => 1
        }};

    ok !$test_client_cr->needs_pow_verification, 'POW is not needed';
};

subtest 'edd status verified' => sub {

    $user->add_client($test_client_cr);
    $uploaded = {
        proof_of_income => {
            documents   => 'something',
            is_uploaded => 1
        }};
    $user->update_edd_status(
        status           => 'passed',
        start_date       => '2021-05-30',
        last_review_date => undef,
        average_earnings => {},
        comment          => 'hello',
        reason           => 'social_responsibility'
    );
    ok !$test_client_cr->needs_pow_verification, 'POW is not needed';
};

subtest 'edd status pending with pending document' => sub {

    $user->add_client($test_client_cr);
    $uploaded = {
        proof_of_income => {
            documents   => 'something',
            is_uploaded => 1
        }};
    $user->update_edd_status(
        status           => 'pending',
        start_date       => '2021-05-30',
        last_review_date => undef,
        average_earnings => {},
        comment          => 'hello',
        reason           => 'card_deposit_monitoring'
    );
    ok $test_client_cr->needs_pow_verification, 'POW is needed';
};

subtest 'edd status contacted' => sub {

    $user->add_client($test_client_cr);
    $uploaded = {
        proof_of_income => {
            documents   => 'something',
            is_uploaded => 1
        }};
    $user->update_edd_status(
        status           => 'contacted',
        start_date       => '2021-05-30',
        last_review_date => undef,
        average_earnings => {},
        comment          => 'hello',
        reason           => 'card_deposit_monitoring'
    );
    ok $test_client_cr->needs_pow_verification, 'POW is needed';
};

$mocked_documents->unmock_all;

done_testing();

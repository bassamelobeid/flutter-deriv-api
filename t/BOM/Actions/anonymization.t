use strict;
use warnings;

use Test::More;
use Test::Deep;
use feature 'state';
use Test::MockModule;
use BOM::Event::Actions::P2P;
use BOM::Test;
use BOM::Test::Email;
use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use BOM::Platform::Context;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Utility qw(random_email_address);

use JSON::MaybeUTF8 qw(decode_json_utf8);

subtest return_undef_and_send_email_to_compliance_if_user_is_not_anonymizable => sub {
    my $BRANDS = BOM::Platform::Context::request()->brand();

    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock('valid_to_anonymize', sub { return 0 });

    my $user = BOM::User->create(
        email    => random_email_address,
        password => BOM::User::Password::hashpw('password'));

    # Add a CR client to the user
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        date_joined => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
    });
    $user->add_client($cr_client);

    mailbox_clear();
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $cr_client->loginid});
    my $msg = mailbox_search(subject => qr/Anonymization failed for/);

    # It should return undef
    is($result, undef, qq/Return undef if user shouldn't anonymize./);

    # It should send an notification email to compliance
    like($msg->{subject}, qr/Anonymization failed for/,       qq/Compliance receive an email if user shouldn't anonymize./);
    like($msg->{body},    qr/has at least one active client/, qq/Compliance receive an email if user shouldn't anonymize./);
    cmp_deeply($msg->{to}, [$BRANDS->emails('compliance')], qq/Email should send to the compliance team./);
};

subtest users_clients_will_set_to_disabled_after_anonymization => sub {
    # Mock BOM::User module
    my $mock_user_module = Test::MockModule->new('BOM::User');
    $mock_user_module->mock('valid_to_anonymize', sub { return 1 });

    # Mock BOM::User::Client module
    my $mock_client_module = Test::MockModule->new('BOM::User::Client');
    $mock_client_module->mock('anonymize_client',                          sub { return 1 });
    $mock_client_module->mock('remove_client_authentication_docs_from_S3', sub { return 1 });

    my @user_clients = ();
    $mock_client_module->mock('get_user_loginids_list', sub { return @user_clients });

    my $email = random_email_address;

    my $client_details = {
        date_joined => Date::Utility->new()->_minus_years(11)->datetime_yyyymmdd_hhmmss,
        broker_code => 'VRTC',
    };

    # We should create a user we call it user
    my $user = BOM::User->create(
        email    => $email,
        password => BOM::User::Password::hashpw('password'));
    my $user_id = $user->id;

    my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    $client_details->{broker_code} = 'CR';
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_details);

    # Add clients to the user.
    $user->add_client($vr_client);
    $user->add_client($cr_client);

    # @user_clients used in mocking process.
    push @user_clients,
        ({
            v_buid    => $user_id,
            v_loginid => $vr_client->loginid
        },
        {
            v_buid    => $user_id,
            v_loginid => $cr_client->loginid
        });

    # Anonymize user
    my $result = BOM::Event::Actions::Anonymization::anonymize_client({'loginid' => $cr_client->loginid});

    ok($result, 'Returns 1 after user anonymized.');

    # Retrieve anonymized user from database by id
    my $anonymized_user = BOM::User->new(id => $user_id);
    my @anonymized_clients = $anonymized_user->clients(include_disabled => 1);

    foreach my $anonymized_client (@anonymized_clients) {
        my $disabled_status = $anonymized_client->status->disabled;
        is($disabled_status->{staff_name}, 'system', sprintf("System disabled the client (%s).", $anonymized_client->loginid));
        is(
            $disabled_status->{reason},
            'Anonymized client',
            sprintf('Client (%s) is disabled because it was anonymized.', $anonymized_client->loginid));
    }
};

# TODO: We should add more tests here for `anonymize_client` code which was written in the past.

done_testing()

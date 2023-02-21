use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use BOM::Test::Email;
use BOM::User::Client;

my $email    = 'test-binary' . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');
my $now      = Date::Utility->today();

# Since the database function get_recent_high_risk_clients fails in circleci (because of the included dblink),
# database access method is mocked here, returning a predefined expected result.
my $mock_EDD = Test::MockModule->new("BOM::User::Script::EDDClientsUpdate");
my $expected_db_rows;
my $returned_db_rows;
$mock_EDD->mock(
    _get_recent_EDD_clients => sub {
        return $expected_db_rows;
    });

my @emitted;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit' => sub { push @emitted, [@_]; });

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

$user->add_client($client_cr);

my $c_no_args = BOM::User::Script::EDDClientsUpdate->new();

my %args = (landing_companies => ['CR']);
my $c    = BOM::User::Script::EDDClientsUpdate->new(%args);

subtest 'class arguments validation' => sub {
    is($c_no_args, undef, 'arguments must be provided to intialize');
};
subtest 'no EDD client CR company' => sub {
    my $landing_company = 'CR';

    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    ok(!@$EDD_clients, 'no client found having more than 20k deposit.');
    ok !$client_cr->status->unwelcome,             'client is not unwelcome';
    ok !$client_cr->status->allow_document_upload, "client do need to submit documents";
    clear_clients($client_cr);
};
subtest 'add payment client CR company with n/a status' => sub {
    my $landing_company = 'CR';

    $expected_db_rows = [{
            loginid          => $client_cr->loginid,
            binary_user_id   => $user->id,
            status           => 'n/a',
            start_date       => $now->date_yyyymmdd,
            last_review_date => $now->date_yyyymmdd,
            comment          => 'client deposited over 20k in cards',
            reason           => 'card_deposit_monitoring'
        }];
    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    ok(!@$EDD_clients, 'no new clients found having more than 20k with n/a EDD status set');
    ok !$client_cr->status->unwelcome,            'client is not unwelcome';
    ok $client_cr->status->allow_document_upload, "Pending EDD docs/info";
    is($emitted[0][1]->{properties}->{first_name}, $client_cr->{first_name},      'first name is correct');
    is($emitted[0][0],                             'request_edd_document_upload', 'event name is correct');
    ok @emitted, 'request_edd_document_upload event emitted correctly';
    clear_clients($client_cr);
};

subtest 'add payment client CR company with pending status but after 5 days' => sub {
    my $landing_company = 'CR';
    $expected_db_rows = [{
            loginid          => $client_cr->loginid,
            binary_user_id   => $user->id,
            status           => 'contacted',
            start_date       => $now->minus_time_interval('5d')->date_yyyymmdd,
            last_review_date => $now->minus_time_interval('5d')->date_yyyymmdd,
            comment          => 'client deposited over 20k in cards',
            reason           => 'card_deposit_monitoring'
        }];
    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    ok(!@$EDD_clients, 'no client found having more than 20k deposit after 5 day mark.');
    ok !$client_cr->status->unwelcome,             'client is not unwelcome';
    ok !$client_cr->status->allow_document_upload, "client do need to submit documents";
    clear_clients($client_cr);
};

subtest 'add payment client CR company with pending status' => sub {
    my $landing_company = 'CR';
    $expected_db_rows = [{
            loginid          => $client_cr->loginid,
            binary_user_id   => $user->id,
            status           => 'contacted',
            start_date       => $now->minus_time_interval('7d')->date_yyyymmdd,
            last_review_date => $now->minus_time_interval('7d')->date_yyyymmdd,
            comment          => 'client deposited over 20k in cards',
            reason           => 'card_deposit_monitoring'
        }];
    $returned_db_rows = [{
            login_id => $client_cr->loginid,
        }];
    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    is @$EDD_clients, @$returned_db_rows, 'Correct number of affected users';
    is_deeply $EDD_clients, $returned_db_rows, 'Returned client ids are correct';
    ok $client_cr->status->unwelcome,             'client is not unwelcome';
    ok $client_cr->status->allow_document_upload, "Pending EDD docs/info";
    $c->send_mail_to_complaince({'test' => ''});
    my $email = mailbox_search(subject => qr/CompOps - Card Transaction Monitoring/);
    ok $email, 'Email sent';
    mailbox_clear();
    clear_clients($client_cr);
};

subtest 'add payment client CR company with pending status with unwelcome' => sub {
    my $landing_company = 'CR';
    $client_cr->status->setnx('unwelcome', 'system', 'Pending EDD docs/info');
    $client_cr->status->upsert('allow_document_upload', 'system', 'Pending EDD docs/info');
    $expected_db_rows = [{
            loginid          => $client_cr->loginid,
            binary_user_id   => $user->id,
            status           => 'pending',
            start_date       => $now->minus_time_interval('7d')->date_yyyymmdd,
            last_review_date => $now->minus_time_interval('7d')->date_yyyymmdd,
            comment          => 'client deposited over 20k in cards',
            reason           => 'card_deposit_monitoring'
        }];
    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    ok(!@$EDD_clients, 'no new clients found having more than 20k deposit after 7 day mark.');
    ok $client_cr->status->unwelcome,             'client is set unwelcome';
    ok $client_cr->status->allow_document_upload, "client need to submit documents";
    clear_clients($client_cr);
};

subtest 'add payment client CR company with no EDD status set' => sub {
    my $landing_company = 'CR';
    $expected_db_rows = [{
            loginid          => $client_cr->loginid,
            binary_user_id   => $user->id,
            status           => undef,
            start_date       => undef,
            last_review_date => undef,
            comment          => undef,
            reason           => undef
        }];
    my $EDD_clients = $c->_update_EDD_clients_status($landing_company);
    ok(!@$EDD_clients, 'no new clients found having more than 20k with no EDD status set');
    ok !$client_cr->status->unwelcome,            'client is not unwelcome';
    ok $client_cr->status->allow_document_upload, "Pending EDD docs/info";
    is($emitted[0][1]->{properties}->{first_name}, $client_cr->{first_name},      'first name is correct');
    is($emitted[0][0],                             'request_edd_document_upload', 'event name is correct');
    ok @emitted, 'request_edd_document_upload event emitted correctly';
    clear_clients($client_cr);
};

sub clear_clients {
    for my $client (@_) {
        $client->status->clear_unwelcome();
        $client->status->clear_allow_document_upload();
    }
}

done_testing();


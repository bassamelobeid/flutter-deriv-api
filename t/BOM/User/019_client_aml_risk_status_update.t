use strict;
use warnings;

use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::User::Client;
use BOM::User::Script::AMLClientsUpdate;
use BOM::User::Password;
use Test::MockModule;

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    residence      => 'id',
    binary_user_id => $user->id
});

$user->add_client($client_vr);
$user->add_client($client_cr);

my $res;
my $c_no_args = BOM::User::Script::AMLClientsUpdate->new();

my %args = (landing_companies => ['CR']);
my $c = BOM::User::Script::AMLClientsUpdate->new(%args);

my $mocked_aml_update = Test::MockModule->new('BOM::User::Script::AMLClientsUpdate');

$mocked_aml_update->mock(
    get_unauthenticated_not_locked_high_risk_clients => sub {
        my @res = ();
        return \@res;
    });
$mocked_aml_update->mock(
    emit_aml_status_change_event => sub {
        return 1;
    });

subtest 'class arguments validation' => sub {
    is($c_no_args, undef, 'arguments must be provided to intialize');
};
subtest 'low aml risk client CR company' => sub {
    my $landing_company = 'CR';
    $client_cr->aml_risk_classification('high');
    $res = $client_cr->save;
    $client_cr->aml_risk_classification('low');
    $res = $client_cr->save;

    is($client_cr->aml_risk_classification, 'low', "aml risk is low");

    my $aml_high_clients = $c->get_unauthenticated_not_locked_high_risk_clients($landing_company);
    ok(!@$aml_high_clients, 'no client found having aml risk high.');
    $mocked_aml_update->unmock('get_unauthenticated_not_locked_high_risk_clients');
};

subtest 'aml risk becomes high CR landing company' => sub {
    my $landing_company = 'CR';
    $client_cr->aml_risk_classification('low');
    $res = $client_cr->save;
    $client_cr->aml_risk_classification('high');
    $res = $client_cr->save;

    #no matter what client aml risk was previously, its latest should be high to be able to picked up
    is($client_cr->aml_risk_classification, 'high', "aml risk becomes high");
    $mocked_aml_update->mock(
        get_unauthenticated_not_locked_high_risk_clients => sub {
            my @res = ({login_ids => $client_cr->loginid});
            return \@res;
        });
    my $aml_high_clients = $c->get_unauthenticated_not_locked_high_risk_clients($landing_company);
    my $update_client_status_loginid = (@$aml_high_clients) ? @{$aml_high_clients}[0]->{login_ids} : '';

    is($update_client_status_loginid, $client_cr->loginid, "fetched correct aml high risk client");

    #update client status
    $c->update_aml_high_risk_clients_status($aml_high_clients);
    # client has withdrawal_locked status
    ok(defined $client_cr->status->withdrawal_locked, "client is withdrawal_locked");
    # client has allow_document_upload status
    ok(defined $client_cr->status->allow_document_upload, "client is allow_document_upload");

    #send email
    $c->update_aml_high_risk_clients_status($aml_high_clients);

    my $res = $c->emit_aml_status_change_event('CR', $aml_high_clients);
    ok($res, "aml status change event emitted");

    # lets try checking again fetch aml high risk clients, this time we should not get any because we already set withdrawal_locked to all of them.
    $mocked_aml_update->mock(
        get_unauthenticated_not_locked_high_risk_clients => sub {
            my @res = ();
            return \@res;
        });
    $aml_high_clients = $c->get_unauthenticated_not_locked_high_risk_clients($landing_company);
    ok(!@$aml_high_clients, 'All AML high risk client set to withdrawal_locked status already.');
    $mocked_aml_update->unmock_all();
};

done_testing();


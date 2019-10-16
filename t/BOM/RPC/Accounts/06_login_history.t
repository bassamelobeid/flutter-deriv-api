use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use Email::Stuffer::TestLinks;
use utf8;
use Data::Dumper;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

################################################################################
# init data
################################################################################

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_login_history(
    environment => 'dummy environment',
    successful  => 't',
    action      => 'logout',
    app_id      => '1098'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_loginid);

################################################################################
# start test
################################################################################

my $method = 'login_history';
my $params = {
    language => 'EN',
    token    => 12345
};
$c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
$params->{token} = $token;
$test_client->status->set('disabled', 1, 'test disabled');
$c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'check invalid token');
$test_client->status->clear_disabled;

my $res = $c->call_ok($method, $params)->result;
is scalar(@{$res->{records}}), 1, 'got correct number of login history records';
is $res->{records}->[0]->{action},      'logout',            'login history record has action key';
is $res->{records}->[0]->{environment}, 'dummy environment', 'login history record has environment key';
ok $res->{records}->[0]->{time},        'login history record has time key';

#create 100 history items for testing the limit
for (1 .. 100) {
    $user->add_login_history(
        environment => 'dummy environment',
        successful  => 't',
        action      => 'logout',
        app_id      => '1098'
    );
}

$res = $c->call_ok($method, $params)->result;
is scalar(@{$res->{records}}), 10, 'default limit 10';
$params->{args} = {limit => 15};
$res = $c->call_ok($method, $params)->result;
is scalar(@{$res->{records}}), 15, 'limit ok';

$params->{args} = {limit => 60};
$res = $c->call_ok($method, $params)->result;
is scalar(@{$res->{records}}), 50, 'max limit is 50';

done_testing();

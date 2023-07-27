use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;
use Test::MockModule;
use Test::Exception;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;

use await;

my $t = build_wsapi_test({language => 'EN'});

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$client_vr->set_default_account('USD');
$client_vr->email($email);
$client_vr->save;
my $vr_1 = $client_vr->loginid;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

$user->add_client($client_vr);


$client_vr = BOM::User::Client->new({loginid => $client_vr->loginid});

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);
$t->await::authorize({authorize => $token});

my $client_dbh = BOM::Test::Data::Utility::UnitTestDatabase->instance->db_handler;
diag("start to lock transaction.transaction");
$client_dbh->begin_work;
$client_dbh->do('lock transaction.transaction');
diag("locked");

diag("will call topup_virtual, that will block rpc worker");
throws_ok {
    # it is expected that message_ok will fail, lets mock ok to ignore this failure
    my $mock_more = Test::MockModule->new('Test::More');
    $mock_more->mock('ok',sub {1});
    my $mock_await = Test::MockModule->new('await');
    $mock_await->mock('ok', sub{1});
    $t->await::topup_virtual({topup_virtual => 1},{wait_max => 1});
} qr/timeout/, "topup_virtual should be timeout because table is locked and then rpc worker is blocked";
diag("Now rpc worker is blocked");
diag("reset binary-websocket-api connection");
BOM::Test::Helper::reconnect($t);
lives_ok {$t->await::ping({ping => 1}); } "ping ok because it will not use rpc woker";

# Here it will fail because rpc worker is blocked
lives_ok {
    $t->await::trading_times({trading_times => "2023-07-26"},{wait_max => 1});
} "trade_time should be ok if rpc worker is available";

diag("unlock table");
$client_dbh->rollback;
diag("lock again");
# lock again
$client_dbh->begin_work;
$client_dbh->do('lock transaction.transaction');
diag("locked");
diag("reset binary-websocket-api connection");
BOM::Test::Helper::reconnect($t);
lives_ok {
    $t->await::trading_times({trading_times => "2023-07-26"},{wait_max => 1});
} "trade_time should still be ok even db locked again because rpc worker is free and it needn't that table";
diag("unlock table");
$client_dbh->rollback;

$t->finish_ok;
done_testing();


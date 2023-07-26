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
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_vr->set_default_account('USD');
$client_vr->email($email);
$client_vr->save;
$client_cr->set_default_account('USD');
$client_cr->email($email);
$client_cr->save;
my $vr_1 = $client_vr->loginid;
my $cr_1 = $client_cr->loginid;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

$user->add_client($client_vr);
$user->add_client($client_cr);

# non-virtual account is not allowed
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $cr_1;

#my ($res, $call_params) = call_mocked_consumer_groups_request($t, {topup_virtual => 1});
#is $call_params->{language}, 'EN';
#ok exists $call_params->{token};
#is $res->{msg_type}, 'topup_virtual';
#ok $res->{error}->{message} =~ /demo accounts only/, 'demo accounts only';

# virtual is ok
$client_vr = BOM::User::Client->new({loginid => $client_vr->loginid});
my $old_balance = $client_vr->default_account->balance;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);
    $authorize = $t->await::authorize({authorize => $token});

my $clientdb = BOM::Test::Data::Utility::UnitTestDatabase->instance->db_handler;
diag("start to lock transaction.transaction");
$clientdb->begin_work;
$clientdb->do('lock transaction.transaction');
diag("locked");

my $t0 = time();
throws_ok {
    # it is expected that message_ok will fail, lets mock ok to ignore this failure
    my $mock = Test::MockModule->new('Test::More');
    $mock->mock('ok',sub {1});
    my $mock2 = Test::MockModule->new('await');
    $mock2->mock('ok', sub{1});
    $t->await::topup_virtual({topup_virtual => 1},{wait_max => 1});
} qr/timeout/, "throws timeout";
diag("end time" . (time - $t0));
BOM::Test::Helper::reconnect($t);
$t->await::ping({ping => 1});

$t->await::trading_times({trading_times => "2023-07-26"});
$clientdb->rollback;
$t->finish_ok;
done_testing();

=POD

my $topup_amount = $res->{topup_virtual}->{amount};
ok $topup_amount, 'topup ok';

$client_vr = BOM::User::Client->new({loginid => $client_vr->loginid});
ok $old_balance + $topup_amount == $client_vr->default_account->balance, 'balance is right';

$t->finish_ok;

done_testing();

=CUT

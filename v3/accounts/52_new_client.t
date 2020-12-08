use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Scalar::Util qw( looks_like_number );

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Script::RpcRedis;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;

use await;

my $t = build_wsapi_test();

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_vr->email($email);
$client_vr->save;
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

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

## test statement
my $statement = $t->await::statement({
    statement => 1,
    limit     => 1
});
ok($statement->{statement});
is($statement->{statement}->{count}, 0);
is_deeply $statement->{statement}->{transactions}, [];
test_schema('statement', $statement);

## test profit table
my $profit_table = $t->await::profit_table({
    profit_table => 1,
    limit        => 1
});
ok($profit_table->{profit_table});
is($profit_table->{profit_table}->{count}, 0);
is_deeply $profit_table->{profit_table}->{transactions}, [];
test_schema('profit_table', $profit_table);

## test disabled
$client_vr->status->set('disabled', 'test.t', "just for test");
my $res = $t->await::profit_table({
    profit_table => 1,
    limit        => 1
});

is $res->{error}->{code}, 'DisabledClient', 'you can not call any authenticated api after disabled.';

my $rpc_redis = BOM::Test::Script::RpcRedis->new('mt5');

subtest 'mt5 new account dry run' => sub {

    $client_cr->set_default_account('USD');
    $token     = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);
    $authorize = $t->await::authorize({authorize => $token});
    is $authorize->{authorize}->{loginid}, $cr_1;

    my $params = {
        account_type    => 'gaming',
        country         => 'mt',
        email           => 'test.account@binary.com',
        name            => 'Meta traderman',
        mainPassword    => 'Efgh4567',
        leverage        => 100,
        dry_run         => 1,
        mt5_new_account => 1,
    };
    $res = $t->await::mt5_new_account($params);
    is $res->{msg_type}, 'mt5_new_account';
    is $res->{error}, undef, 'has no error in response';
    test_schema('mt5_new_account', $res);
};

subtest 'mt5 new swap-free account dry run' => sub {
    $email     = 'abcd@binary.com';
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->email($email);
    $client_cr->save;
    $cr_1 = $client_cr->loginid;

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $user->add_client($client_cr);
    $client_cr->set_default_account('USD');
    $token     = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);
    $authorize = $t->await::authorize({authorize => $token});
    is $authorize->{authorize}->{loginid}, $cr_1;

    my $params = {
        account_type         => 'gaming',
        mt5_account_category => 'swap_free',
        country              => 'mt',
        email                => 'test.account@binary.com',
        name                 => 'Meta traderman',
        mainPassword         => 'Efgh4567',
        leverage             => 100,
        dry_run              => 1,
        mt5_new_account      => 1,
    };
    $res = $t->await::mt5_new_account($params);
    is $res->{msg_type}, 'mt5_new_account';
    is $res->{error}, undef, 'has no error in response';
    test_schema('mt5_new_account', $res);
};

subtest 'mt5 new swap free account for Spain' => sub {
    $email = 'abcde@binary.com';
    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_mlt->email($email);
    $client_mlt->save;
    my $mlt_1 = $client_mlt->loginid;

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $user->add_client($client_mlt);
    $client_mlt->set_default_account('USD');
    $token     = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_1);
    $authorize = $t->await::authorize({authorize => $token});
    is $authorize->{authorize}->{loginid}, $mlt_1;

    my $params = {
        account_type         => 'gaming',
        mt5_account_category => 'swap_free',
        country              => 'es',
        email                => 'test.account@binary.com',
        name                 => 'Meta traderman',
        mainPassword         => 'Efgh4567',
        leverage             => 100,
        dry_run              => 1,
        mt5_new_account      => 1,
    };
    $res = $t->await::mt5_new_account($params);
    is $res->{msg_type}, 'mt5_new_account';
    is $res->{error}->{code}, 'GamingAccountMissing', ' Gaming account is not allowed in Spain';
};

my $pid = $rpc_redis->pid;
ok looks_like_number($pid), "Valid consumer worker process id: $pid";
$rpc_redis->stop_script();
ok !kill(0, $pid), 'Consumer worker process killed successfully';

$t->finish_ok;

done_testing();

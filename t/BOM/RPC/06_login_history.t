use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::System::Password;
use Data::Dumper;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua );

################################################################################
# init data
################################################################################

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                                                             broker_code => 'CR',
                                                                            });
$test_client->email($email);
$test_client->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
                                               email    => $email,
                                               password => $hash_pwd
                                              );
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->add_login_history({
                          environment => 'dummy environment',
                          successful  => 't',
                          action      => 'logout',
                         });
$user->save;

my $token = BOM::Platform::SessionCookie->new(
                                              loginid => $test_loginid,
                                              email   => $email
                                             )->token;


################################################################################
# start test
################################################################################

my $method = 'login_history';
my $params = {language => 'zh_CN', token => $token};

diag( Dumper( $c->call_ok($method, $params)->result));

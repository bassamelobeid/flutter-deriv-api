use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../../../lib";
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;
use Test::MockModule;
use utf8;
use Data::Dumper;

################################################################################
# init test data
################################################################################

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                                                             broker_code => 'MF',
                                                                            });
$test_client->email($email);
$test_client->save;

my $token = BOM::Platform::SessionCookie->new(
                                              loginid => $test_client->loginid,
                                              email   => $email
                                             )->token;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
################################################################################
# start test
################################################################################
my $method = 'paymentagent_list';
my $params = {
              language => 'zh_CN',
              token    => '12345'
             };

diag(Dumper($c->call_ok($method, $params)->has_no_error->result));



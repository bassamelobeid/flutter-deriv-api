use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $email       = 'test@binary.com';
$test_client->save;
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                                                        broker_code => 'VRTC',
                                                                        email => $email,
                                                                               });
my $loginid = $client->loginid;

my $token = BOM::Platform::SessionCookie->new(
                                              loginid => $loginid,
                                              email   => $email
                                             )->token;

$client->deposit_virtual_funds;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'buy' => sub {
  ok(1);
};

done_testing();

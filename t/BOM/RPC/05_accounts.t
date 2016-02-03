use Test::Most;
use Test::Mojo;
use TestUts;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = Test::Mojo->new('BOM::RPC');

my $c = MojoX::JSON::RPC::Client->new( ua => $t->app->ua);

sub test_call{
  my @args = @_;
  TestUts::test_call($c,@args);
}

#test_call('/payout_currencies',{id => Data::UUID->new()->create_str(), method => 'payout_currencies', params => {client_loginid => 'CR0021'}},{result => 1}, 'test');
diag(Dumper($c->call('/payout_currencies',{id => Data::UUID->new()->create_str(), method => 'payout_currencies', params => {client_loginid => 'CR0021'}})->result));
done_testing();

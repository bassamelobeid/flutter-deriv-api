use Test::Most;
use Test::Mojo;
use TestUts;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = Test::Mojo->new('BOM::RPC');

my $c = MojoX::JSON::RPC::Client->new( ua => $t->app->ua);

sub call_params{
  my $method = shift;
  my $params = shift;
  return ("/$method",{id => Data::UUID->new()->create_str(), method => $method, params => $params});
}

sub test_call{
  my @args = @_;
  TestUts::test_call($c,@args);
}

#test_call('/payout_currencies',{id => Data::UUID->new()->create_str(), method => 'payout_currencies', params => {client_loginid => 'CR0021'}},{result => 1}, 'test');
is_deeply($c->call(call_params('payout_currencies', {client_loginid => 'CR0021'}))->result,['USD'];
done_testing();

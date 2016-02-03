use Test::Most;
use Test::Mojo;
use TestUts;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

package MojoX::JSON::RPC::Client;
sub tcall{
  my $self = shift;
  my $method = shift;
  my $params = shift;
  return $self->call("/$method",{id => Data::UUID->new()->create_str(), method => $method, params => $params})->result;
}

package main;

my $t = Test::Mojo->new('BOM::RPC');

my $c = MojoX::JSON::RPC::Client->new( ua => $t->app->ua);

is_deeply($c->tcall('payout_currencies', {client_loginid => 'CR0021'}),['USD']);
is_deeply($c->tcall('payout_currencies',{}),[]);
done_testing();

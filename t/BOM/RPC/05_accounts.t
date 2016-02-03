use Test::Most;
use Test::Mojo;
use Test::MockModule;
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

subtest 'payout_currencies' => sub{
  my $m = ref(BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica'));
  my $mocked_m = Test::MockModule->new($m,no_auto => 1);
  my $mocked_currency = [qw(A B C)];
  is_deeply($c->tcall('payout_currencies', {client_loginid => 'CR0021'}),['USD'],"will return client's currency");
  $mocked_m->mock('legal_allowed_currencies',sub{return $mocked_currency});
  is_deeply($c->tcall('payout_currencies',{}),$mocked_currency,"will return legal currencies");
};

subtest 'landing_company' => sub {
  is_deeply($c->tcall('landing_company', {args => {landing_company => 'ab'}}),{},"will return client's currency");
};

done_testing();

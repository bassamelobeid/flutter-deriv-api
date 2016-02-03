use Test::Most;
use Test::Mojo;
use Test::MockModule;
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

my $method = 'payout_currencies';
subtest $method => sub{
  my $m = ref(BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica'));
  my $mocked_m = Test::MockModule->new($m,no_auto => 1);
  my $mocked_currency = [qw(A B C)];
  is_deeply($c->tcall($method, {client_loginid => 'CR0021'}),['USD'],"will return client's currency");
  $mocked_m->mock('legal_allowed_currencies',sub{return $mocked_currency});
  is_deeply($c->tcall($method,{}),$mocked_currency,"will return legal currencies");
};

$method = 'landing_company';
subtest $method => sub {
  is_deeply($c->tcall($method, {args => {landing_company => 'ab'}}),
            {error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
  my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
  ok($ag_lc->{gaming_company}, "ag have gaming company");
  ok($ag_lc->{financial_company}, "ag have financial company");
  ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company}, "de have no gaming_company");
  ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest $method => sub {
  is_deeply($c->tcall($method, {args => {landing_company_details => 'ab'}}),
            {
             error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
  
};

done_testing();

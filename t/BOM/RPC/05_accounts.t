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
  is_deeply($c->tcall($method, {args => {landing_company => 'nosuchcountry'}}),
            {error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
  my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
  ok($ag_lc->{gaming_company}, "ag have gaming company");
  ok($ag_lc->{financial_company}, "ag have financial company");
  ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company}, "de have no gaming_company");
  ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest $method => sub {
  is_deeply($c->tcall($method, {args => {landing_company_details => 'nosuchcountry'}}),
            {
             error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
  is($c->tcall($method, {args => {landing_company_details => 'costarica'}})->{name},'Binary (C.R.) S.A.', "details result ok" );
};

$method = 'statement';
subtest $method => sub{
  is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
  is($c->tcall($method,{client_loginid => 'CR0021'})->{count}, 100, 'have 100 statements');
  my $mock_client = Test::MockModule->new('BOM::Platform::Client');
  $mock_client->mock('default_account',sub {undef});
  is($c->tcall($method,{client_loginid => 'CR0021'})->{count}, 0, 'have 0 statements if no default account');
  $mock_client;
  my $mock_Portfolio = Test::MockModule->new('BOM::RPC::v3::PortfolioManagement');
  my $_sell_expired_is_called = 0;
  $mock_Portfolio->mock('_sell_expired_contracts',sub {$_sell_expired_is_called = 1; $mock_Portfolio->original('_sell_expired_contracts')->(@_)});
  my $result = $c->tcall($method,{client_loginid => 'CR0021'});
  ok($_sell_expired_is_called, "_sell_expired_contracts is called");
#  my $mocked_transaction = Test::MockModule->new('BOM::Database::DataMapper::Transaction');
#my $txns = [
#            {
#             id => 1,
#             amount => 1,
#             action_type => 'deposit',
#             balance_after => int(rand(10000000)),
#             financial_market_bet_id => undef,
#             payment_time => int(rand(10000000)),
#            },
#            {
#             id => 1,
#             amount => 1,
#             action_type => 'buy',
#             balance_after => int(rand(10000000)),
#             financial_market_bet_id => int(rand(10000000)),
#             sell_time => int(rand(10000000)),
#
#            },
#
#
#           ]
#$mocked_transaction->mock('get_transactions_ws',sub {return });
#is(result->{transactions}[0]{transaction_time},'1454483594', 'transaction time correct');
};

done_testing();

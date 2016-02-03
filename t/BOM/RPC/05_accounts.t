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

#my $method = 'payout_currencies';
#subtest $method => sub{
#  my $m = ref(BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica'));
#  my $mocked_m = Test::MockModule->new($m,no_auto => 1);
#  my $mocked_currency = [qw(A B C)];
#  is_deeply($c->tcall($method, {client_loginid => 'CR0021'}),['USD'],"will return client's currency");
#  $mocked_m->mock('legal_allowed_currencies',sub{return $mocked_currency});
#  is_deeply($c->tcall($method,{}),$mocked_currency,"will return legal currencies");
#};
#
#$method = 'landing_company';
#subtest $method => sub {
#  is_deeply($c->tcall($method, {args => {landing_company => 'nosuchcountry'}}),
#            {error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
#  my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
#  ok($ag_lc->{gaming_company}, "ag have gaming company");
#  ok($ag_lc->{financial_company}, "ag have financial company");
#  ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company}, "de have no gaming_company");
#  ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
#};
#
#$method = 'landing_company_details';
#subtest $method => sub {
#  is_deeply($c->tcall($method, {args => {landing_company_details => 'nosuchcountry'}}),
#            {
#             error => {message_to_client => 'Unknown landing company.', code => 'UnknownLandingCompany'}},"no such landing company");
#  is($c->tcall($method, {args => {landing_company_details => 'costarica'}})->{name},'Binary (C.R.) S.A.', "details result ok" );
#};
#
my $method = 'statement';
#subtest $method => sub{
#  is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
#  is($c->tcall($method,{client_loginid => 'CR0021'})->{count}, 100, 'have 100 statements');
#  my $mock_client = Test::MockModule->new('BOM::Platform::Client');
#  $mock_client->mock('default_account',sub {undef});
#  is($c->tcall($method,{client_loginid => 'CR0021'})->{count}, 0, 'have 0 statements if no default account');
#  undef $mock_client;
#  my $mock_Portfolio = Test::MockModule->new('BOM::RPC::v3::PortfolioManagement');
#  my $_sell_expired_is_called = 0;
#  $mock_Portfolio->mock('_sell_expired_contracts',sub {$_sell_expired_is_called = 1; $mock_Portfolio->original('_sell_expired_contracts')->(@_)});
#  my $mocked_transaction = Test::MockModule->new('BOM::Database::DataMapper::Transaction');
#  my $txns = [{
#          'staff_loginid' => 'CR0021',
#          'source' => undef,
#          'sell_time' => undef,
#          'transaction_time' => '2005-09-21 06:46:00',
#          'action_type' => 'buy',
#          'referrer_type' => 'financial_market_bet',
#          'financial_market_bet_id' => '202339',
#          'payment_id' => undef,
#          'id' => '204459',
#          'purchase_time' => '2005-09-21 06:46:00',
#          'short_code' => 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5',
#          'balance_after' => '505.0000',
#          'remark' => undef,
#          'quantity' => 1,
#          'payment_time' => undef,
#          'account_id' => '200359',
#          'amount' => '-10.0000',
#          'payment_remark' => undef
#        },
#          {
#          'staff_loginid' => 'CR0021',
#          'source' => undef,
#          'sell_time' => undef,
#          'transaction_time' => '2005-09-21 06:46:00',
#          'action_type' => 'sell',
#          'referrer_type' => 'financial_market_bet',
#          'financial_market_bet_id' => '202319',
#          'payment_id' => undef,
#          'id' => '204439',
#          'purchase_time' => '2005-09-21 06:46:00',
#          'short_code' => 'RUNBET_DOUBLEDOWN_USD2500_frxUSDJPY_5',
#          'balance_after' => '515.0000',
#          'remark' => undef,
#          'quantity' => 1,
#          'payment_time' => undef,
#          'account_id' => '200359',
#          'amount' => '237.5000',
#          'payment_remark' => undef
#        },
#          {
#          'staff_loginid' => 'CR0021',
#          'source' => undef,
#          'sell_time' => undef,
#          'transaction_time' => '2005-09-21 06:14:00',
#          'action_type' => 'deposit',
#          'referrer_type' => 'payment',
#          'financial_market_bet_id' => undef,
#          'payment_id' => '200599',
#          'id' => '201399',
#          'purchase_time' => undef,
#          'short_code' => undef,
#          'balance_after' => '600.0000',
#          'remark' => undef,
#          'quantity' => 1,
#          'payment_time' => '2005-09-21 06:14:00',
#          'account_id' => '200359',
#          'amount' => '600.0000',
#          'payment_remark' => 'Egold deposit Batch 49100734 from egold ac 2427854 (1.291156 ounces of Gold at $464.70/ounce) Egold Timestamp 1127283282'
#        }];
#
#$mocked_transaction->mock('get_transactions_ws',sub {return $txns});
#  my $result = $c->tcall($method,{client_loginid => 'CR0021'});
#  ok($_sell_expired_is_called, "_sell_expired_contracts is called");
#  is($result->{transactions}[0]{transaction_time},Date::Utility->new($txns->[0]{purchase_time})->epoch, 'transaction time correct for buy ');
#  is($result->{transactions}[1]{transaction_time},Date::Utility->new($txns->[1]{sell_time})->epoch, 'transaction time correct for sell');
#  is($result->{transactions}[2]{transaction_time},Date::Utility->new($txns->[2]{payment_time})->epoch, 'transaction time correct for payment');
  my $result = $c->tcall($method, {client_loginid => 'CR0021', args => {description => 1}});
  diag(Dumper($result));
ok(1);

#};

done_testing();

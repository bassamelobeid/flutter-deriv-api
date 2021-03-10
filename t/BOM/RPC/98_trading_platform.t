use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;

my $c = BOM::Test::RPC::QueueClient->new();

subtest 'dxtrader accounts' => sub {
    
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    
    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $client->account('USD');
    
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = { language => 'EN' };
    
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');
    
    $params->{token} = $token;
    $params->{args}{platform} = 'xxx';
    
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('TradingPlatformError', 'bad params');

    $params->{args} = {
        platform => 'dxtrade',
        account_type => 'demo',
        market_type => 'financial',
        password    => 'test',
    };

    my $acc = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;
    
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error
        ->error_code_is('ExistingDXtradeAccount', 'error code for duplicate account.')
        ->error_message_like(qr/You already have DXtrade account of this type/, 'error message for duplicate account');

    $params->{args} = {
        platform => 'dxtrade',
    };

    my $list = $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error->result;
    delete $list->[0]{stash};
    delete $acc->{stash};
    cmp_deeply(
        $list,
        [ $acc ],
        'account list returns created account',
    );

};

ok 1;

done_testing();

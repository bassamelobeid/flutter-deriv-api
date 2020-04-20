use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time);

use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);

my $mock_sb = Test::MockModule->new('WebService::SendBird');
my $mock_sb_user = Test::MockModule->new('WebService::SendBird::User');
set_fixed_time(0);

my %last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        %last_event = ( type => $type, data => $data );
    });

subtest 'create_advertiser' => sub {
    my $client = BOM::Test::Helper::P2P::create_client();
    my %params = ( name => 'advertiser 1 name' );
    
    $mock_sb->mock('create_user', sub { die });
    is exception { $client->p2p_advertiser_create(%params) }->{error_code} => 'AdvertiserCreateChatError', 'handle sb api error';
    
    my $user_id = rand(999);
    $mock_sb->mock('create_user', sub {
        my ($self, %params) = @_;
        my $t = time;
        ok $params{user_id} =~ /p2puser_CR_\d+_$t/, 'sendbird user_id includes timestamp'; 
        return WebService::SendBird::User->new(
             api_client  => 1,
             user_id => $user_id,
             session_tokens =>  [{
                    'session_token' => 'dummy',
                    'expires_at'    => (time + 7200) * 1000,
            }]
        )
    });
    is $client->p2p_advertiser_create(%params)->{chat_user_id}, $user_id, 'advertiser create chat user id';
    is $client->p2p_advertiser_info()->{chat_user_id}, $user_id, 'advertiser info chat user id';
    is $client->p2p_advertiser_update(is_approved=>1)->{chat_user_id}, $user_id, 'advertiser update chat user id';
};

subtest 'chat_token' => sub {
    my $client = BOM::Test::Helper::P2P::create_client();

    is exception { $client->p2p_chat_token() }->{error_code} => 'AdvertiserNotFoundForChatToken', 'client is non-advertiser';
    
    my $expiry = 7200;  # to match BOM::User::Client::p2p_chat_token()
    
    my $advertiser = $client->p2p_advertiser_create(name => 'advertiser 2 name');
    is $advertiser->{chat_token}, 'dummy', 'token issued when advertiser created';;

    $mock_sb_user->mock('issue_session_token', sub { die });
    my $resp = $client->p2p_chat_token();
    is $resp->{token}, 'dummy', 'token not reissued';
    is $resp->{expiry_time}, $expiry, 'correct expiry time';
    
    set_fixed_time(1);
    is exception { $client->p2p_chat_token() }->{error_code} => 'ChatTokenError', 'handle sb api error';
    
    my $token = rand(999);
    $mock_sb_user->mock('issue_session_token', sub { 
        return {
            'session_token' => $token,
            'expires_at'    => ($expiry+1) * 1000,
         }
    });
    
    $resp = $client->p2p_chat_token();
    is $resp->{token}, $token, 'token not reissued';
    is $resp->{expiry_time}, $expiry+1, 'correct expiry time';    
    
    is $last_event{type}, 'p2p_advertiser_updated', 'event emitted';
    is $last_event{data}->{advertiser_id}, $advertiser->{id}, 'event advertiser id';
    is $last_event{data}->{client_loginid}, $client->loginid, 'event client loginid';

    $advertiser = $client->_p2p_advertisers(loginid => $client->loginid)->[0];
    is $advertiser->{chat_token}, $token, 'token is stored';
    is $advertiser->{chat_token_expiry}, $expiry+1, 'token expiry is stored';
    
    $mock_sb_user->mock('issue_session_token', sub { die });
    is $client->p2p_chat_token()->{token}, $token, 'stored token is returned';
    
    is $client->p2p_advertiser_info()->{chat_token}, $token, 'stored token returned from p2p_advertiser_info';
    is $client->p2p_advertiser_update(is_approved=>1)->{chat_token}, $token, 'stored token returned from p2p_advertiser_update';
};

subtest 'create chat' => sub {
    
    my ( $advertiser, $advert ) = BOM::Test::Helper::P2P::create_advert();
    BOM::Test::Helper::P2P::create_escrow;
    my ( $client, $order ) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    is exception { $client->p2p_chat_create(()) }->{error_code} => 'OrderNotFound', 'empty params';
    is exception { $client->p2p_chat_create(order_id => -1) }->{error_code} => 'OrderNotFound', 'non-existent order';
    is exception { $client->p2p_chat_create(order_id => -1) }->{error_code} => 'OrderNotFound', 'non-existent order';
    is exception { $client->p2p_chat_create(order_id => $order->{id}) }->{error_code} => 'AdvertiserNotFoundForChat', 'client is non-advertiser';

    my $other_client = BOM::Test::Helper::P2P::create_client();
    is exception { $other_client->p2p_chat_create(order_id => $order->{id}) }->{error_code} => 'PermissionDenied', '3rd party client cannot create chat';

    is exception { $advertiser->p2p_chat_create(order_id => $order->{id}) }->{error_code} => 'CounterpartyNotAdvertiserForChat', 'counterparty is non-advertiser';
    $client->p2p_advertiser_create(name=>'advertiser 3 name');
    
    $mock_sb->mock('create_group_chat', sub { die });
    is exception { $advertiser->p2p_chat_create(order_id => $order->{id}); }->{error_code} => 'CreateChatError', 'handle sb api error';
    
    my $channel_url = rand(999);
    $mock_sb->mock('create_group_chat', sub { 
         return WebService::SendBird::GroupChat->new(
             api_client  => 1,
             channel_url => $channel_url,
         );   
    });
    
    my $resp = $advertiser->p2p_chat_create(order_id => $order->{id});
    is $resp->{channel_url}, $channel_url, 'got channel url';
    is $resp->{order_id}, $order->{id}, 'got order id';

    is $last_event{type}, 'p2p_order_updated', 'event emitted';
    is $last_event{data}->{order_id}, $order->{id}, 'event order id';
    is $last_event{data}->{client_loginid}, $advertiser->loginid, 'event client loginid';
    
    is $client->p2p_order_info(id => $order->{id})->{chat_channel_url}, $channel_url, 'channel url saved';
};

done_testing();


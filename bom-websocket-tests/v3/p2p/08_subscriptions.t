use strict;
use warnings;

use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Wrapper::P2P;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advert;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser;
use Binary::WebSocketAPI::v3::Subscription::P2P::Order;
use JSON::MaybeUTF8 qw(:v1);

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock(
        'stash',
        sub {
            my $self = shift;
            my $key  = shift;
            if (defined $key) {
                return $self->{stash}->{$key};
            }
            return $self->{stash};
        });
    $c->mock('tx',                          sub { });
    $c->mock('send',                        sub { shift; $c->{send_data} = shift; });
    $c->mock('finish',                      sub { my $self = shift; $self->{stash} = {} });
    $c->mock('is_invalid_loginid_argument', sub { });
    return $c;
}

subtest 'Wrapper::P2P subscribe_orders' => sub {
    my $c = mock_c();

    $c->{stash}->{loginid} = 1;
    $c->{stash}->{broker}  = 'cr';
    my $req = {
        msg_type => 'p2p_order_info',
        args     => {subscribe => 1}};
    my $rpc_response = {subscription_info => {advertiser_id => 2}};
    my $results;
    lives_ok {
        $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_orders($c, $rpc_response, $req);
    }
    'subscribe_orders';

    like($results->{subscription}{id}, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct subscription');
    is $results->{'msg_type'}, 'p2p_order_info', 'msg_type matches';
};

subtest 'Wrapper::P2P subscribe_advertisers' => sub {
    my $c = mock_c();

    my $req = {
        msg_type => 'p2p_advertiser_create',
        args     => {subscribe => 1}};
    my $rpc_response = {};
    my $results;

    subtest 'request with missing loginid from stash' => sub {
        $rpc_response->{client_loginid} = 'CR123';
        lives_ok {
            $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_advertisers($c, $rpc_response, $req);
        }
        'subscribe_advertisers';
        is $results->{subscription}{id}, undef, 'No subscription - missing loginid';
    };

    subtest 'request with correct args' => sub {
        $c->{stash}->{loginid} = 1;

        $rpc_response->{client_loginid} = 'CR1234';
        lives_ok {
            $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_advertisers($c, $rpc_response, $req);
        }
        'subscribe_advertisers';
        like($results->{subscription}{id}, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct subscription');
        is $results->{'msg_type'}, 'p2p_advertiser_create', 'msg_type matches';
    };

};

subtest 'Wrapper::P2P subscribe_adverts' => sub {
    my $c = mock_c();

    my $req = {
        msg_type => 'p2p_advert_info',
        args     => {
            subscribe => 1,
            id        => 1
        }};
    my $rpc_response = {};
    my $results;

    subtest 'request with missing loginid from stash' => sub {
        lives_ok {
            $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_adverts($c, $rpc_response, $req);
        }
        'subscribe_adverts';
        is $results->{subscription}{id}, undef, 'No subscription - missing loginid';
    };

    subtest 'request with correct args' => sub {
        $c->{stash}->{loginid} = 1;

        $rpc_response->{advertiser_id}         = '1234';
        $rpc_response->{advertiser_account_id} = '5';
        lives_ok {
            $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_adverts($c, $rpc_response, $req);
        }
        'subscribe_adverts';
        like($results->{subscription}{id}, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct subscription');
        is $results->{'msg_type'}, 'p2p_advert_info', 'msg_type matches';
    };

};

subtest 'Wrapper::P2P subscribe_p2p_settings' => sub {
    my $c = mock_c();

    my $req = {
        msg_type => 'p2p_settings',
        args     => {subscribe => 1}};
    my $rpc_response = {subscription_info => {country => 'eg'}};
    my $results;

    lives_ok {
        $results = Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_p2p_settings($c, $rpc_response, $req);
    }
    'subscribe_p2p_settings';
    like($results->{subscription}{id}, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct subscription');
    is $results->{'msg_type'}, 'p2p_settings', 'msg_type matches';
};

done_testing();

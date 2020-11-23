use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Format::Util::Numbers qw(formatnumber);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;

populate_exchange_rates();

BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::bypass_sendbird();

my %last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        %last_event = (
            type => $type,
            data => $data
        );
    });

subtest 'Order dispute (type buy)' => sub {
    my $time      = time;
    my %ad_params = (
        amount         => 100,
        rate           => 3.1,
        type           => 'sell',
        description    => 'ad description',
        payment_method => 'bank_transfer',
        payment_info   => 'ad pay info',
        contact_info   => 'ad contact info',
        local_currency => 'sgd',
    );

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        %ad_params,
        advertiser => {
            first_name => 'test',
            last_name  => 'asdf'
        });

    my $order_amount = 100;
    my ($client, $new_order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        balance   => $order_amount,
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $new_order->{id});
    my $response = $client->p2p_create_order_dispute(
        id             => $new_order->{id},
        dispute_reason => 'seller_not_released',
        skip_livechat  => 1,
    );

    my $expected_response = {
        disputer_loginid => $client->loginid,
        dispute_reason   => 'seller_not_released',
    };

    cmp_deeply(
        \%last_event,
        {
            type => 'p2p_order_updated',
            data => {
                client_loginid => $client->loginid,
                order_id       => $new_order->{id},
                order_event    => 'dispute'
            }
        },
        'p2p_order_updated event emitted'
    );

    is $response->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response->{dispute_details}, $expected_response, 'order_dispute expected response after client complaint');

    subtest 'dispute time not set in redis' => sub {
        my $p2p_redis   = BOM::Config::Redis->redis_p2p_write();
        my $disputed_at = $p2p_redis->zrangebyscore(BOM::User::Client::P2P_ORDER_DISPUTED_AT, $time, time);
        is scalar $disputed_at->@*, 0, 'Dispute time not set in redis (therefore livechat is skipped)';
    };

    BOM::Test::Helper::P2P::set_order_disputable($client, $new_order->{id});
    my $response_advertiser = $advertiser->p2p_create_order_dispute(
        id             => $new_order->{id},
        dispute_reason => 'buyer_underpaid',
    );

    my $expected_response_advertiser = {
        dispute_reason   => 'buyer_underpaid',
        disputer_loginid => $advertiser->loginid,
    };

    is $response_advertiser->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response_advertiser->{dispute_details}, $expected_response_advertiser, 'order_dispute expected response after advertiser complaint');
};

subtest 'Order dispute (type sell)' => sub {
    my $time = time;

    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    BOM::Test::Helper::P2P::set_order_disputable($advertiser, $order->{id});
    my $response = $advertiser->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'buyer_underpaid',
    );

    my $expected_response = {
        disputer_loginid => $advertiser->loginid,
        dispute_reason   => 'buyer_underpaid',
    };

    is $response->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response->{dispute_details}, $expected_response, 'order_dispute expected response after advertiser complaint');

    subtest 'dispute time set in redis' => sub {
        my $p2p_redis   = BOM::Config::Redis->redis_p2p_write();
        my $disputed_at = $p2p_redis->zrangebyscore(BOM::User::Client::P2P_ORDER_DISPUTED_AT, $time, time);
        cmp_deeply($disputed_at, superbagof(join('|', $order->{id}, $client->broker_code)), 'Disputed order found in the ZSET');
    };

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    my $response_client = $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'buyer_not_paid',
    );

    my $expected_response_client = {
        dispute_reason   => 'buyer_not_paid',
        disputer_loginid => $client->loginid,
    };

    is $response_client->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response_client->{dispute_details}, $expected_response_client, 'order_dispute expected response after client complaint');
};

subtest 'Seller can confirm under dispute' => sub {
    my %ad_params = (
        amount         => 100,
        rate           => 3.1,
        type           => 'sell',
        description    => 'ad description',
        payment_method => 'bank_transfer',
        payment_info   => 'ad pay info',
        contact_info   => 'ad contact info',
        local_currency => 'sgd',
    );

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        %ad_params,
        advertiser => {
            first_name => 'test',
            last_name  => 'asdf'
        });

    my $order_amount = 100;
    my ($client, $new_order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        balance   => $order_amount,
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $new_order->{id});
    my $response = $client->p2p_create_order_dispute(
        id             => $new_order->{id},
        dispute_reason => 'seller_not_released',
    );

    my $expected_response = {
        disputer_loginid => $client->loginid,
        dispute_reason   => 'seller_not_released',
    };

    is $response->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response->{dispute_details}, $expected_response, 'order_dispute expected response after client complaint');

    my $confirm = $advertiser->p2p_order_confirm(
        id => $new_order->{id},
    );

    is $confirm->{status}, 'completed', 'P2P Order completed by seller';
};

subtest 'Buyer cannot confirm under dispute' => sub {
    my %ad_params = (
        amount         => 100,
        rate           => 3.1,
        type           => 'sell',
        description    => 'ad description',
        payment_method => 'bank_transfer',
        payment_info   => 'ad pay info',
        contact_info   => 'ad contact info',
        local_currency => 'sgd',
    );

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        %ad_params,
        advertiser => {
            first_name => 'test',
            last_name  => 'asdf'
        });

    my $order_amount = 100;
    my ($client, $new_order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        balance   => $order_amount,
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $new_order->{id});
    my $response = $client->p2p_create_order_dispute(
        id             => $new_order->{id},
        dispute_reason => 'seller_not_released',
    );

    my $expected_response = {
        disputer_loginid => $client->loginid,
        dispute_reason   => 'seller_not_released',
    };

    is $response->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response->{dispute_details}, $expected_response, 'order_dispute expected response after client complaint');

    my $exception = exception {
        $client->p2p_order_confirm(
            id => $new_order->{id},
        );
    };

    is $exception->{error_code}, 'OrderUnderDispute', 'Buyer cannot confirm order under dispute';
};

subtest 'Edge cases' => sub {
    # Frontend relies on expiration time rather than states for placing the complain button
    # due to this we may allow buyer-confirmed if the order is indeed expired.

    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'buyer-confirmed');

    my $response = $advertiser->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'waiting in vain',
    );

    my $expected_response = {
        disputer_loginid => $advertiser->loginid,
        dispute_reason   => 'waiting in vain',
    };

    is $response->{status}, 'disputed', 'Order is disputed';
    cmp_deeply($response->{dispute_details}, $expected_response, 'order_dispute expected response after complaint from buyer-confirmed');
};

subtest 'Order cannot be disputed' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );
    my ($advertiser2, $advert2) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );

    my ($client2, $order2) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert2->{id},
        balance   => $amount
    );

    my $err;
    $err = exception {
        $client2->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid'
        );
    };
    is $err->{error_code}, 'OrderNotFound', 'Order not found for unrelated client';

    $err = exception {
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid'
        );
    };
    is $err->{error_code}, 'InvalidStateForDispute', 'Invalid status for dispute';

    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'refunded');
    $err = exception {
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_underpaid'
        );
    };
    is $err->{error_code}, 'InvalidFinalStateForDispute', 'Invalid final status for dispute';

    $err = exception {
        $client2->p2p_create_order_dispute(
            id             => $order2->{id} * -1,
            dispute_reason => 'buyer_underpaid'
        );
    };
    is $err->{error_code}, 'OrderNotFound', 'Order not found';

    $err = exception {
        $advertiser2->p2p_create_order_dispute(
            id             => $order2->{id},
            dispute_reason => 'buyer_not_paid'
        );
    };
    is $err->{error_code}, 'InvalidReasonForBuyer', 'Invalid reason for buyer (advertiser on sell order)';

    $err = exception {
        $client2->p2p_create_order_dispute(
            id             => $order2->{id},
            dispute_reason => 'seller_not_released'
        );
    };
    is $err->{error_code}, 'InvalidReasonForSeller', 'Invalid reason for seller (client on sell order)';

    $err = exception {
        $advertiser->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'seller_not_released'
        );
    };
    is $err->{error_code}, 'InvalidReasonForSeller', 'Invalid reason for seller (advertiser on buy order)';

    $err = exception {
        $client->p2p_create_order_dispute(
            id             => $order->{id},
            dispute_reason => 'buyer_not_paid'
        );
    };
    is $err->{error_code}, 'InvalidReasonForBuyer', 'Invalid reason for buyer (client on buy order)';
};

subtest 'Returning dispute fields' => sub {
    my %ad_params = (
        amount         => 100,
        rate           => 3.1,
        type           => 'sell',
        description    => 'ad description',
        payment_method => 'bank_transfer',
        payment_info   => 'ad pay info',
        contact_info   => 'ad contact info',
        local_currency => 'sgd',
    );

    my $escrow = BOM::Test::Helper::P2P::create_escrow();

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        %ad_params,
        advertiser => {
            first_name => 'test',
            last_name  => 'asdf'
        });

    my $client       = BOM::Test::Helper::P2P::create_advertiser();
    my $order_amount = 100;
    my $new_order    = $client->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => $order_amount,
        expiry    => 7200,
    );

    my $expected_response = {
        dispute_reason   => undef,
        disputer_loginid => undef,
    };

    cmp_deeply($new_order->{dispute_details}, $expected_response, 'order_create expected response');

    BOM::Test::Helper::P2P::set_order_disputable($client, $new_order->{id});
    # modify expected response accordingly
    $expected_response->{dispute_details} = {
        disputer_loginid => $client->loginid,
        dispute_reason   => 'Bank is under assault',
    };
    $expected_response->{is_under_dispute} = 1;
    $expected_response->{status}           = 'disputed';

    $client->p2p_create_order_dispute(
        id             => $new_order->{id},
        dispute_reason => 'Bank is under assault',
    );

    $expected_response = {
        dispute_reason   => 'Bank is under assault',
        disputer_loginid => $client->loginid,
    };

    my $response = $client->p2p_order_list(
        id => $new_order->{id},
    );

    cmp_deeply($response->[0]->{dispute_details}, $expected_response, 'order_list expected response after dispute');

    $response = $client->p2p_order_info(
        id => $new_order->{id},
    );

    cmp_deeply($response->{dispute_details}, $expected_response, 'order_info expected response after dispute');

    BOM::Test::Helper::P2P::set_order_status($client, $new_order->{id}, 'pending');
    $response = $client->p2p_expire_order(
        id => $new_order->{id},
    );

    cmp_deeply(
        \%last_event,
        {
            type => 'p2p_order_updated',
            data => {
                client_loginid => $client->loginid,
                order_id       => $response->{id},
                order_event    => 'expired'
            }
        },
        'p2p_order_updated event emitted'
    );

    cmp_deeply($response->{dispute_reason},   $expected_response->{dispute_reason},   'order_expire expected dispute_reason after cancel');
    cmp_deeply($response->{disputer_loginid}, $expected_response->{disputer_loginid}, 'order_expire expected disputer_loginid after cancel');
};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Date::Utility;
use Time::Moment;

use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Context                     qw(request);
use BOM::Platform::Context::Request;
use BOM::Config::Runtime;
use Brands;

my (@identify_args, @track_args, @transactional_args, @emissions);
my $mock_segment = new Test::MockModule('WebService::Async::Segment::Customer');

my $brand    = Brands->new->name;
my ($app_id) = Brands->new->whitelist_apps->%*;
my $req      = BOM::Platform::Context::Request->new(
    brand_name => $brand,
    app_id     => $app_id
);
request($req);

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->transaction_verification_countries([]);
$config->transaction_verification_countries_all(0);

$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return Future->done(1);
    },
    'track' => sub {
        my ($customer, %args) = @_;
        push @track_args, ($customer, \%args);
        return Future->done(1);
    });

my $mock_cio = new Test::MockModule('WebService::Async::CustomerIO');
$mock_cio->redefine(
    'send_transactional' => sub {
        @transactional_args = @_;
        return Future->done(1);
    });

my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->redefine(
    'emit' => sub {
        my ($event, $args) = @_;
        push @emissions,
            {
            type    => $event,
            details => $args
            };
    });

BOM::Test::Helper::P2P::bypass_sendbird();
my $escrow = BOM::Test::Helper::P2P::create_escrow();
my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
    amount => 100,
    type   => 'sell'
);

my ($client, $order) = BOM::Test::Helper::P2P::create_order(
    advert_id => $advert->{id},
    amount    => 99.1,
);

subtest 'p2p order event validation' => sub {

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;

    is $handler->({})->get,   0, 'retruns zero on error';
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    0, 'Segment track is not called';

    undef @emissions;
    $handler->({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        })->get;
    is scalar @emissions, 1, 'event emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[0])->get;
    is scalar @identify_args, 0, 'Segment identify is not called - order_type is missing';
    is scalar @track_args,    0, 'Segment track is not called- order_type is missing';
};

subtest 'p2p order created' => sub {
    $client->user->update_preferred_language('ID');
    $advertiser->user->update_preferred_language('RU');

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_created};
    undef @identify_args;
    undef @track_args;
    undef @emissions;

    $handler->({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        })->get;
    is scalar @emissions, 1, 'event emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[0])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my $order = $client->_p2p_orders(id => $order->{id})->[0];

    my ($customer, $args) = @track_args;

    my (undef, $args_buyer, undef, $args_seller) = @track_args;

    is $args_buyer->{event}, 'p2p_order_created', 'Track event name is correct';

    is_deeply $args_buyer->{properties},
        {
        loginid          => $client->loginid,
        user_role        => 'buyer',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expire_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'ID'
        },
        'properties are set properly for p2p_order_created event';

    is $args_seller->{event}, 'p2p_order_created', 'Track event name is correct';

    is_deeply $args_seller->{properties},
        {
        loginid          => $advertiser->loginid,
        user_role        => 'seller',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expire_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'RU'
        },
        'properties are set properly for p2p_order_created event';
};

subtest 'p2p order created transactional' => sub {
    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_created};
    undef @identify_args;
    undef @track_args;
    undef @emissions;
    undef @transactional_args;

    $handler->({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        })->get;
    is scalar @emissions, 1, 'event emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[0])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my $order = $client->_p2p_orders(id => $order->{id})->[0];

    my ($customer, $args) = @track_args;

    my (undef, $args_buyer, undef, $args_seller) = @track_args;

    is $args_buyer->{event},  'track_p2p_order_created', 'Track event name is correct';
    is $args_seller->{event}, 'track_p2p_order_created', 'Track event name is correct';
    ok @transactional_args, 'transactional email is sent';
    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);
};

subtest 'p2p order confirmed by buyer' => sub {
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;

    $client->p2p_order_confirm(id => $order->{id});
    my $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'buyer-confirmed', 'order status is changed';
    undef @emissions;

    $handler->({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
            order_event    => 'confirmed',
        })->get;
    is scalar @emissions, 1, 'event emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my ($customer, $args) = @track_args;
    my (undef, $args_buyer, undef, $args_seller) = @track_args;

    is $args_buyer->{event}, 'p2p_order_buyer_has_paid', 'Track event name is correct';

    is_deeply $args_buyer->{properties},
        {
        loginid          => $client->loginid,
        user_role        => 'buyer',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expire_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'ID'
        },
        'properties are set properly for p2p_order_buyer_has_paid event';

    is $args_seller->{event}, 'p2p_order_buyer_has_paid', 'Track event name is correct';

    is_deeply $args_seller->{properties},
        {
        loginid          => $advertiser->loginid,
        user_role        => 'seller',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expire_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'RU'
        },
        'properties are set properly for p2p_order_buyer_has_paid event';
};

subtest 'p2p order confirmed by seller' => sub {
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;

    $advertiser->p2p_order_confirm(id => $order->{id});

    my $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'completed', 'order status is changed';
    undef @emissions;

    $handler->({
            client_loginid => $advertiser->loginid,
            order_id       => $order->{id},
            order_event    => 'confirmed',
        })->get;
    is scalar @emissions, 1, 'events emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my (undef, $args_buyer, undef, $args_seller) = @track_args;

    is $args_buyer->{event}, 'p2p_order_seller_has_released', 'Track event name is correct';

    is_deeply $args_buyer->{properties},
        {
        loginid          => $client->loginid,
        user_role        => 'buyer',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'ID'
        },
        'properties are set properly for p2p_order_seller_has_released event';

    is $args_seller->{event}, 'p2p_order_seller_has_released', 'Track event name is correct';

    is_deeply $args_seller->{properties},
        {
        loginid          => $advertiser->loginid,
        user_role        => 'seller',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'RU'
        },
        'properties are set properly for p2p_order_seller_has_released event';
};

subtest 'p2p order cancelled' => sub {
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;
    undef @emissions;

    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'cancelled');

    my $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'cancelled', 'order status is changed';

    $handler->({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
            order_event    => 'cancelled',
        })->get;

    is scalar @emissions, 1, 'events emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my ($customer, $args) = @track_args;

    my (undef, $args_buyer, undef, $args_seller) = @track_args;

    is $args_buyer->{event}, 'p2p_order_cancelled', 'Track event name is correct';

    is_deeply $args_buyer->{properties},
        {
        loginid          => $client->loginid,
        user_role        => 'buyer',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'ID'
        },
        'properties are set properly for p2p_order_cancelled event';

    is $args_seller->{event}, 'p2p_order_cancelled', 'Track event name is correct';

    is_deeply $args_seller->{properties},
        {
        loginid          => $advertiser->loginid,
        user_role        => 'seller',
        order_id         => $order->{id},
        order_type       => 'buy',
        amount           => '99.10',
        currency         => 'USD',
        seller_nickname  => $order->{advertiser_name},
        seller_user_id   => $advertiser->binary_user_id,
        buyer_nickname   => $order->{client_name} // '',
        buyer_user_id    => $client->binary_user_id,
        exchange_rate    => '1.00',
        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand            => $brand,
        local_currency   => 'IDR',
        lang             => 'RU'
        },
        'properties are set properly for p2p_order_cancelled event';
};

subtest 'pending order expired' => sub {
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 100
    );

    BOM::Test::Helper::P2P::expire_order($client, $order->{id});
    $client->p2p_expire_order(id => $order->{id});
    $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'refunded', 'order status is changed';

    undef @emissions;
    $handler->({
            client_loginid => $advertiser->loginid,
            order_id       => $order->{id},
            order_event    => 'expired',
        })->get;
    is scalar @emissions, 1, 'events emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my ($customer1, $args1, $customer2, $args2) = @track_args;

    my $expected_properties = {
        loginid             => $client->loginid,
        user_role           => 'buyer',
        order_id            => $order->{id},
        order_type          => 'buy',
        amount              => '100.00',
        currency            => 'USD',
        seller_nickname     => $order->{advertiser_name},
        seller_user_id      => $advertiser->binary_user_id,
        buyer_nickname      => $order->{client_name} // '',
        buyer_user_id       => $client->binary_user_id,
        buyer_has_confirmed => 0,
        exchange_rate       => '1.00',
        order_created_at    => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand               => $brand,
        local_currency      => 'IDR',
        lang                => 'EN'
    };
    is $args1->{event}, 'p2p_order_expired', 'Track event name is correct';
    is_deeply $args1->{properties}, $expected_properties, 'properties are set properly for p2p_order_expired event (buyer)';

    is $args2->{event}, 'p2p_order_expired', 'Track event name is correct';
    is_deeply $args2->{properties},
        {
        %$expected_properties,
        loginid   => $advertiser->loginid,
        user_role => 'seller'
        },
        'properties are set properly for p2p_order_expired event (seller)';
};

subtest 'confirmed order expired' => sub {
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{p2p_order_updated};
    undef @identify_args;
    undef @track_args;

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 100
    );

    $client->p2p_order_confirm(id => $order->{id});
    $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'buyer-confirmed', 'corfirmed order status';

    BOM::Test::Helper::P2P::expire_order($client, $order->{id});
    $client->p2p_expire_order(id => $order->{id});
    $order = $client->_p2p_orders(id => $order->{id})->[0];
    is $order->{status}, 'timed-out', 'Payed order status is changed to timed-out after expiration';
    undef @emissions;
    $handler->({
            client_loginid => $advertiser->loginid,
            order_id       => $order->{id},
            order_event    => 'expired',
        })->get;
    is scalar @emissions, 1, 'event emitted';

    BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
    is scalar @identify_args, 0, 'Segment identify is not called';
    is scalar @track_args,    4, 'Segment track is called twice';

    my ($customer1, $args1, $customer2, $args2) = @track_args;

    my $expected_properties = {
        loginid             => $client->loginid,
        user_role           => 'buyer',
        order_id            => $order->{id},
        order_type          => 'buy',
        amount              => '100.00',
        currency            => 'USD',
        seller_nickname     => $order->{advertiser_name},
        seller_user_id      => $advertiser->binary_user_id,
        buyer_nickname      => $order->{client_name} // '',
        buyer_user_id       => $client->binary_user_id,
        buyer_has_confirmed => 1,
        exchange_rate       => '1.00',
        order_created_at    => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
        brand               => $brand,
        local_currency      => 'IDR',
        lang                => 'EN'
    };
    is $args1->{event}, 'p2p_order_expired', 'Track event name is correct';
    is_deeply $args1->{properties}, $expected_properties, 'properties are set properly for p2p_order_expired event (buyer)';

    is $args2->{event}, 'p2p_order_expired', 'Track event name is correct';
    is_deeply $args2->{properties},
        {
        %$expected_properties,
        loginid   => $advertiser->loginid,
        user_role => 'seller'
        },
        'properties are set properly for p2p_order_expired event (seller)';
};

subtest 'p2p_advert_created' => sub {
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{p2p_advert_created};
    undef @track_args;

    my $event_args;
    $mock_events->mock(
        'emit' => sub {
            if ($_[0] eq 'p2p_advert_created') { $event_args = $_[1]; $handler->($event_args)->get; }
        });

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
    cmp_deeply $track_args[1]->{properties},
        {
        %$event_args,
        brand => ignore(),
        lang  => ignore()
        },
        'track event properties';
};

subtest 'p2p_advert_created transactional' => sub {
    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);

    my $handler = BOM::Event::Process->new(category => 'track')->actions->{p2p_advert_created};
    undef @track_args;
    undef @transactional_args;
    $mock_events->mock(
        'emit' => sub {
            if ($_[0] eq 'p2p_advert_created') { my $event_args = $_[1]; $handler->($event_args)->get; }
        });
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;
    ok @track_args,         'track event sent';
    ok @transactional_args, 'transactional email is sent';

    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);
};

subtest 'p2p_advertiser_cancel_at_fault' => sub {
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{p2p_advertiser_cancel_at_fault};

    undef @track_args;
    my %args = (
        loginid           => $client->loginid,
        order_id          => 123,
        cancels_remaining => 2
    );
    $handler->(\%args)->get;

    cmp_deeply $track_args[1]->{properties},
        {
        %args,
        brand => ignore(),
        lang  => ignore()
        },
        'track event properties';
};

subtest 'p2p_advertiser_temp_banned' => sub {
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{p2p_advertiser_temp_banned};

    undef @track_args;
    my %args = (
        loginid        => $client->loginid,
        order_id       => 789,
        limit          => 3,
        block_end_date => '2030-01-01',
        block_end_time => '23:59',
    );
    $handler->(\%args)->get;

    cmp_deeply $track_args[1]->{properties},
        {
        %args,
        brand => ignore(),
        lang  => ignore()
        },
        'track event properties';
};

subtest 'phone_number_verification' => sub {
    my $handler = BOM::Event::Process->new(category => 'track')->actions->{phone_number_verification};

    undef @track_args;
    my %args = (
        loginid    => $client->loginid,
        properties => {
            live_chat_url    => 'http://live.chat',
            verification_url => 'http://verify.me/testcode',
            code             => 'testcode',
            email            => 'user@test.com',
            language         => 'EN',
            first_name       => 'Dude',
            broker_code      => 'MF',
        },
    );
    $handler->(\%args)->get;

    cmp_deeply $track_args[1]->{properties},
        {
        $args{properties}->%*,
        loginid => $client->loginid,
        brand   => ignore(),
        lang    => ignore()
        },
        'track event properties';
};

done_testing()

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use JSON::MaybeXS;

use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Rules::Engine;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::create_payment_methods();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->payment_methods_enabled(1);

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

subtest 'updating all advert fields' => sub {

    my %params = (
        is_active        => 1,
        account_currency => 'USD',
        local_currency   => 'myr',
        amount           => 100,
        description      => 'test advert',
        max_order_amount => 10,
        min_order_amount => 1,
        payment_method   => 'bank_transfer',
        payment_info     => 'ad pay info',
        contact_info     => 'ad contact info',
        rate             => 1.0,
        rate_type        => 'fixed',
        type             => 'sell',
    );

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    my $advert     = $advertiser->p2p_advert_create(%params);

    cmp_deeply(exception { $advertiser->p2p_advert_update(id => -1, is_listed => 0) }, {error_code => 'AdvertNotFound'}, 'invalid id');

    cmp_deeply(exception { $advertiser->p2p_advert_update() }, {error_code => 'AdvertNotFound'}, 'no id');

    my $client = BOM::Test::Helper::P2P::create_advertiser();
    cmp_deeply(
        exception { $client->p2p_advert_update(id => $advert->{id}, is_listed => 0) },
        {error_code => 'PermissionDenied'},
        "Other client cannot edit advert"
    );

    ok !$advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    )->{is_active}, "Deactivate advert";

    ok !$advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, "advert is inactive";

    my $ad_info = $advertiser->p2p_advert_info(id => $advert->{id});

    @emitted_events = ();
    my $empty_update = $advertiser->p2p_advert_update(id => $advert->{id});
    cmp_deeply($empty_update, $ad_info, 'empty update returns all fields');
    ok !@emitted_events, 'no events emitted for empty update';

    my $real_update = $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );
    $ad_info->{is_active} = $ad_info->{is_visible} = 1;
    delete $ad_info->{visibility_status};
    cmp_deeply($real_update, $ad_info, 'actual update returns all fields');

    cmp_deeply(
        \@emitted_events,
        [['p2p_adverts_updated', {advertiser_id => $advert->{advertiser_details}{id}}]],
        'p2p_adverts_updated event emitted for advert update'
    );

    is $advertiser->p2p_advert_update(
        id   => $advert->{id},
        rate => 1.1
    )->{rate}, 1.1, 'update rate';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, rate => 0.0000001) },
        {
            error_code     => 'RateTooSmall',
            message_params => ignore()
        },
        'rate validation'
    );

    my $order = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 10
    );

    $config->limits->maximum_advert(200);

    $advert = $advertiser->p2p_advert_update(
        id               => $advert->{id},
        remaining_amount => 100
    );
    cmp_ok $advert->{remaining_amount}, '==', 100, 'update remaining_amount';
    cmp_ok $advert->{amount},           '==', 110, 'adjusted amount includes non-refunded orders';

    BOM::Test::Helper::P2P::set_order_status($advertiser, $order->{id}, 'refunded');

    $advert = $advertiser->p2p_advert_update(
        id               => $advert->{id},
        remaining_amount => 90
    );
    cmp_ok $advert->{amount}, '==', 90, 'amount adjusted correctly with refunded order';

    $advert = $advertiser->p2p_advert_update(
        id               => $advert->{id},
        max_order_amount => 12,
        min_order_amount => 2,
    );

    cmp_deeply $advert->{max_order_amount}, num(12), 'update max_order_amount';
    cmp_deeply $advert->{min_order_amount}, num(2),  'update min_order_amount';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, max_order_amount => 1) },
        {error_code => 'InvalidMinMaxAmount'},
        'min max validation - updating one'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, min_order_amount => 10, max_order_amount => 9.99) },
        {error_code => 'InvalidMinMaxAmount'},
        'min max validation - updating both'
    );

    is $advertiser->p2p_advert_update(
        id          => $advert->{id},
        description => 'hello',
    )->{description}, 'hello', 'update description';

    is $advertiser->p2p_advert_update(
        id           => $advert->{id},
        contact_info => 'call me',
    )->{contact_info}, 'call me', 'update contact_info';

    is $advertiser->p2p_advert_update(
        id           => $advert->{id},
        payment_info => 'pay me',
    )->{payment_info}, 'pay me', 'update payment_info';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, contact_info => ' ') },
        {error_code => 'AdvertContactInfoRequired'},
        'contact_info validation'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_info => ' ') },
        {error_code => 'AdvertPaymentInfoRequired'},
        'payment_info validation'
    );

    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );

    my $advert_dupe = $advertiser->p2p_advert_create(%params);

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1) },
        {error_code => 'AdvertSameLimits'},
        'cannot enable ad with overlapping limits'
    );

    $advertiser->p2p_advert_update(
        id               => $advert->{id},
        min_order_amount => 11,
        max_order_amount => 12
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1) }, undef, 'can enable ad after changing min max');

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, min_order_amount => 1) },
        {error_code => 'AdvertSameLimits'},
        'cannot change limit to overlap'
    );

    $advertiser->p2p_advert_update(
        id     => $advert_dupe->{id},
        delete => 1
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1) }, undef, 'can enable ad after deleting the dupe');

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => ['x', 'y', 'z']) },
        {error_code => 'AdvertPaymentMethodNamesNotAllowed'},
        'payment_method_names validation'
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => []) },
        undef, 'empty payment_method_ids allowed if payment_method exists');

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [1, 2, 3]) },
        {error_code => 'InvalidPaymentMethods'},
        'invalid payment_method_ids'
    );

    my @pms = keys $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method     => 'method1',
                is_enabled => 0,
            },
            {
                method     => 'method2',
                is_enabled => 0,
            }
        ],
    )->%*;

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => \@pms) },
        {error_code => 'ActivePaymentMethodRequired'},
        'inactive payment_method_ids'
    );

    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );

    is(exception { $advert = $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => \@pms) },
        undef, 'inactive payment_method_ids on disabled ad');

    ok !$advert->{payment_method}, 'payment_method removed after adding payment_method_ids';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1) },
        {error_code => 'ActivePaymentMethodRequired'},
        'cannot enable ad with no active pms'
    );

    is(exception { $advert = $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => []) },
        undef, 'can set empty payment_method_ids on disabled ad');

    $advertiser->p2p_advertiser_payment_methods(update => {map { $_ => {is_enabled => 1} } @pms});

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1, payment_method_ids => \@pms) },
        undef, 'can enable ad and set active payment_method_ids');

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => []) },
        {error_code => 'AdvertPaymentMethodRequired'},
        'cannot remove all pms from active ad'
    );

    is $advertiser->p2p_advert_update(
        id             => $advert->{id},
        local_currency => 'ABC',
    )->{local_currency}, 'ABC', 'update local_currency';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, rate_type => 'float') },
        {error_code => 'AdvertFloatRateNotAllowed'},
        'cannot convert ad to floating rate when feature is disabled'
    );
};

subtest 'Updating order_expiry_period of advert' => sub {
    BOM::Test::Helper::P2P::create_escrow();
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(order_expiry_period => 1800);
    is $advert->{order_expiry_period}, 1800, 'expected order_expiry_period for ad';

    my (undef, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
    is $order->{expiry_time}, ($order->{created_time} + $advert->{order_expiry_period}), "order expiry epoch reflected correctly";
    my $initial_expiry_time = $order->{expiry_time};

    @emitted_events = ();
    is $advertiser->p2p_advert_update(
        id                  => $advert->{id},
        order_expiry_period => 900
    )->{order_expiry_period}, 900, 'order_expiry_period updated correctly';

    is $order->{expiry_time}, $initial_expiry_time, "existing order expiry epoch unchanged due to change in advert's order_expiry_period";

    cmp_deeply(
        \@emitted_events,
        [['p2p_adverts_updated', {advertiser_id => $advert->{advertiser_details}{id}}]],
        'p2p_adverts_updated event emitted due to update of order_expiry_period'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id                  => $advert->{id},
                order_expiry_period => 200
            );
        },
        {error_code => 'InvalidOrderExpiryPeriod'},
        'invalid order expiry time error captured correctly'
    );
    BOM::Test::Helper::P2P::create_escrow();
};

subtest 'updating advert fields that will be reflected in orders' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {residence => 'id'},
        balance        => 100
    );

    my %advertiser_methods = $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            },
            {
                method => 'method2',
                tag    => 'm2'
            }])->%*;

    my %methods_by_tag = map { $advertiser_methods{$_}->{fields}{tag}{value} => $_ } keys %advertiser_methods;

    my %test_data = (
        buy => {
            initial_params => {
                is_active            => 1,
                amount               => 100,
                description          => 'test advert',
                max_order_amount     => 10,
                min_order_amount     => 1,
                payment_method_names => ['method1'],
                contact_info         => 'ad contact info',
                rate                 => 1.0,
                rate_type            => 'fixed',
                type                 => 'buy',
            },

            update_params => {
                is_active            => 0,
                description          => 'changed instruction',
                max_order_amount     => 9,
                min_order_amount     => 2,
                payment_method_names => ['method2'],
                contact_info         => 'new contact info',
                rate                 => 2.0
            }
        },
        sell => {
            initial_params => {
                is_active          => 1,
                amount             => 100,
                description        => 'test advert',
                max_order_amount   => 9,
                min_order_amount   => 2,
                payment_method_ids => [$methods_by_tag{m1}],
                contact_info       => 'ad contact info',
                rate               => 1.0,
                rate_type          => 'fixed',
                type               => 'sell',
            },

            update_params => {
                is_active          => 0,
                description        => 'changed instruction',
                max_order_amount   => 8,
                min_order_amount   => 3,
                payment_method_ids => [$methods_by_tag{m2}],
                contact_info       => 'new contact info',
                rate               => 2.0
            }});

    my $advert;
    foreach my $ad_type (keys %test_data) {
        @emitted_events = ();
        $advert         = $advertiser->p2p_advert_create($test_data{$ad_type}->{initial_params}->%*);
        foreach my $field (keys $test_data{$ad_type}->{update_params}->%*) {
            @emitted_events = ();
            $advertiser->p2p_advert_update(
                id     => $advert->{id},
                $field => $test_data{$ad_type}->{update_params}->{$field});
            if ($field =~ m/description|payment_method_names|payment_method_ids/) {
                cmp_deeply(
                    \@emitted_events,
                    [
                        ['p2p_adverts_updated', {advertiser_id => $advert->{advertiser_details}{id}}],
                        [
                            'p2p_advert_orders_updated',
                            {
                                advert_id      => $advert->{id},
                                client_loginid => $advertiser->loginid
                            }]
                    ],
                    "p2p_adverts_updated and p2p_order_advert_updated event emitted when $field updated for $ad_type ad."
                );
            } else {
                cmp_deeply(
                    \@emitted_events,
                    [['p2p_adverts_updated', {advertiser_id => $advert->{advertiser_details}{id}}],],
                    "only p2p_adverts_updated event emitted when $field updated for $ad_type ad."
                );
            }

        }

    }

};

subtest 'Buy ads' => sub {

    my %params = (
        is_active        => 1,
        account_currency => 'USD',
        local_currency   => 'myr',
        amount           => 100,
        description      => 'test advert',
        max_order_amount => 10,
        min_order_amount => 1,
        payment_method   => 'bank_transfer',
        payment_info     => 'ad pay info',
        contact_info     => 'ad contact info',
        rate             => 1.0,
        rate_type        => 'fixed',
        type             => 'buy',
    );

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;
    my $advert     = $advertiser->p2p_advert_create(%params);

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [1, 2, 3]) },
        {error_code => 'AdvertPaymentMethodsNotAllowed'},
        'cannot set payment_method_ids'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => ['x']) },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['x']
        },
        'cannot set invalid payment_method_names'
    );

    is(exception { $advert = $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => ['method2', 'method1']) },
        undef, 'set payment_method_names ok');

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'names are localized and sorted';
    ok !$advert->{payment_method}, 'payment_method removed after adding payment_method_names';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => []) },
        {error_code => 'AdvertPaymentMethodRequired'},
        'cannot set empty payment_method_names'
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, description => 'testing') }, undef, 'can set new description');

    is $advertiser->p2p_advert_info(id => $advert->{id})->{description}, 'testing', 'description was changed';
};

subtest 'Deleting ads' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    BOM::Test::Helper::P2P::create_escrow();
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    for my $status (qw( pending buyer-confirmed timed-out )) {
        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
        cmp_deeply(
            exception {
                $advertiser->p2p_advert_update(
                    id     => $advert->{id},
                    delete => 1
                )
            },
            {error_code => 'OpenOrdersDeleteAdvert'},
            "cannot delete ad with $status order"
        );
    }

    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'cancelled');

    my $resp;
    is exception { $resp = $advertiser->p2p_advert_update(id => $advert->{id}, delete => 1) }, undef, 'can delete ad with cancelled order';
    cmp_deeply $resp,
        {
        id      => $advert->{id},
        deleted => 1
        },
        'response for deleted ad';

    is $advertiser->p2p_advert_info(id => $advert->{id}), undef, 'deleted ad is not seen';

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id   => $advert->{id},
                amount      => 10,
                rule_engine => BOM::Rules::Engine->new(),
            )
        },
        {error_code => 'AdvertNotFound'},
        'cannot create order for deleted ad'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id     => $advert->{id},
                delete => 0,
            )
        },
        {error_code => 'AdvertNotFound'},
        'cannot undelete ad'
    );

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();

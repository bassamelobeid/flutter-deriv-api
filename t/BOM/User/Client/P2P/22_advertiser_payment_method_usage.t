use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Test::Fatal;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    'p2p_payment_methods' => {
        method1 => {
            display_name => 'Method 1',
            fields       => {tag => {display_name => 'ID'}}
        },
        method2 => {
            display_name => 'Method 2',
            fields       => {tag => {display_name => 'ID'}}
        },
        method3 => {
            display_name => 'Method 3',
            fields       => {tag => {display_name => 'ID'}}
        },
    });

$runtime_config->payment_method_countries(
    $json->encode({
            method1 => {mode => 'exclude'},
            method2 => {mode => 'exclude'},
            method3 => {mode => 'exclude'}}));

subtest 'adverts' => sub {

    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    my %methods = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            },
            {
                method => 'method1',
                tag    => 'm2'
            },
            {
                method => 'method2',
                tag    => 'm3'
            }])->%*;
    my %methods_by_tag = map { $methods{$_}->{fields}{tag}{value} => $_ } keys %methods;

    my $advert = $client->p2p_advert_create(
        type               => 'sell',
        amount             => 10,
        min_order_amount   => 1,
        max_order_amount   => 10,
        rate               => 1,
        contact_info       => 'call me',
        payment_method_ids => [keys %methods],
    );

    is $advert->{payment_method}, 'method1,method2', 'payment method names';
    cmp_deeply $advert->{payment_method_details}, \%methods, 'payment method details';

    is exception {
        %methods = $client->p2p_advertiser_payment_methods(
            update => {
                $methods_by_tag{m1} => {is_enabled => 0},
                $methods_by_tag{m2} => {is_enabled => 0}}
            )->%*
    }, undef, 'can disable methods';

    my $ad_info = $client->p2p_advert_info(id => $advert->{id});
    is $ad_info->{payment_method}, 'method2', 'disabled method not shown on ad info';
    cmp_deeply $ad_info->{payment_method_details}, \%methods, 'payment method details';

    cmp_deeply $client->p2p_advertiser_adverts->[0]{payment_method_names}, ['Method 2'], 'advertiser adverts shows method name only';

    my $otherclient = BOM::Test::Helper::P2P::create_advertiser;
    $ad_info = $otherclient->p2p_advert_info(id => $advert->{id});
    ok !exists $ad_info->{payment_method_details}, 'payment_method_details not returned for other client from p2p_advert_info';
    cmp_deeply $ad_info->{payment_method_names}, ['Method 2'], 'payment method names returned to other client from p2p_advert_info';

    cmp_deeply $otherclient->p2p_advert_list(payment_method => ['method2'])->[0]{payment_method_names}, ['Method 2'],
        'payment method names returned to other client from p2p_advert_list';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$methods_by_tag{m3} => {is_enabled => 0}}) },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'not allowed to disable last method'
    );

    is exception { $client->p2p_advertiser_payment_methods(delete => [@methods_by_tag{qw/m1 m2/}]) }, undef, 'allowed to delete unused methods';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(delete => [$methods_by_tag{m3}]) },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'not allowed to delete last method'
    );

    %methods = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm4'
            },
            {
                method => 'method1',
                tag    => 'm5'
            }])->%*;
    %methods_by_tag = map { $methods{$_}->{fields}{tag}{value} => $_ } keys %methods;

    my $update = $client->p2p_advert_update(
        id                 => $advert->{id},
        payment_method_ids => [@methods_by_tag{qw/m4 m5/}]);
    is $update->{payment_method}, 'method1', 'update method name';

    my $pm_details = {
        $methods_by_tag{m4} => $methods{$methods_by_tag{m4}},
        $methods_by_tag{m5} => $methods{$methods_by_tag{m5}},
    };
    cmp_deeply $update->{payment_method_details}, $pm_details, 'update payment method details';

    $update = $client->p2p_advert_update(id => $advert->{id});
    cmp_deeply $update->{payment_method_details}, $pm_details, 'empty update payment method details';

    is exception { $client->p2p_advertiser_payment_methods(delete => [$methods_by_tag{m3}]) }, undef, 'allowed to delete unused methods';

    $client->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );
    is exception { $client->p2p_advertiser_payment_methods(delete => [@methods_by_tag{qw/m4 m5/}]) }, undef,
        'can delete all methods from a disabled ad';
    cmp_deeply exception { $client->p2p_advert_update(id => $advert->{id}, is_active => 1) }, {error_code => 'AdvertNoPaymentMethod'},
        'cannot reactivate ad with no method';

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                type               => 'buy',
                amount             => 10,
                min_order_amount   => 1,
                max_order_amount   => 10,
                rate               => 1,
                payment_method_ids => [keys %methods],
            )
        },
        {error_code => 'AdvertPaymentContactInfoNotAllowed'},
        'cannot provide payment_method_ids for buy ad'
    );

    cmp_deeply(
        exception {
            $client->p2p_advert_create(
                type             => 'buy',
                amount           => 10,
                min_order_amount => 1,
                max_order_amount => 10,
                rate             => 1,
                payment_method   => 'method1, method2, methodx',
            )
        },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['methodx']
        },
        'cannot provide invalid method'
    );

    cmp_deeply(
        exception {
            $advert = $client->p2p_advert_create(
                type             => 'buy',
                amount           => 10,
                min_order_amount => 1,
                max_order_amount => 10,
                rate             => 1,
                payment_method   => 'method2, method1 ',
            )
        },
        undef,
        'can provide valid methods'
    );

    is $advert->{payment_method}, 'method1,method2', 'payment method for buy ad';

    is $client->p2p_advert_update(
        id             => $advert->{id},
        payment_method => ''
    )->{payment_method}, 'method1,method2', 'empty payment method update ignored';

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id             => $advert->{id},
                payment_method => 'method1, method2, methodx',
            )
        },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['methodx']
        },
        'cannot update with invalid method'
    );

    is $client->p2p_advert_update(
        id             => $advert->{id},
        payment_method => 'method3, method1, method2'
    )->{payment_method}, 'method1,method2,method3', 'can update with valid methods';
};

subtest 'sell orders' => sub {

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type           => 'buy',
        payment_method => 'method1,method3'
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    is $client->p2p_advert_list(payment_method => ['method3'])->[0]{id}, $advert->{id}, 'advert list query by method';

    my %methods = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            },
            {
                method => 'method1',
                tag    => 'm2'
            },
            {
                method => 'method2',
                tag    => 'm3'
            }])->%*;
    my %methods_by_tag = map { $methods{$_}->{fields}{tag}{value} => $_ } keys %methods;

    cmp_deeply(
        exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 10, contact_info => 'x', payment_method_ids => [keys %methods]) },
        {
            error_code     => 'PaymentMethodNotInAd',
            message_params => ['Method 2']
        },
        'cannot use method not in ad'
    );

    my $order = $client->p2p_order_create(
        advert_id          => $advert->{id},
        amount             => 10,
        contact_info       => 'x',
        payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m2}]);
    is $order->{payment_method}, 'method1', 'order create payment_method';

    my $pm_details = {
        $methods_by_tag{m1} => $methods{$methods_by_tag{m1}},
        $methods_by_tag{m2} => $methods{$methods_by_tag{m2}},
    };

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details returned from order_create';

    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details,
        'payment_method_details returned from order_info for pending order';

    cmp_deeply $client->p2p_order_list->[0]{payment_method_names}, ['Method 1'], 'payment method names in order list';

    my $order_info = $advertiser->p2p_order_info(id => $order->{id});
    is $order_info->{payment_method}, 'method1', 'counterparty gets payment_method';
    cmp_deeply $order_info->{payment_method_details}, $pm_details, 'counterparty gets payment_method_details';
    cmp_deeply $advertiser->p2p_order_list->[0]{payment_method_names}, ['Method 1'], 'counterparty payment method names in order list';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$methods_by_tag{m1} => {is_enabled => 0}}) },
        {
            error_code     => 'PaymentMethodUsedByOrder',
            message_params => [$order->{id}]
        },
        'not allowed to disable a method'
    );

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$methods_by_tag{m2} => {tag => 'test'}}) },
        {
            error_code     => 'PaymentMethodUsedByOrder',
            message_params => [$order->{id}]
        },
        'not allowed to change a method'
    );

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(delete => [@methods_by_tag{qw/m1 m2/}]) },
        {
            error_code     => 'PaymentMethodUsedByOrder',
            message_params => [$order->{id}]
        },
        'not allowed to delete methods'
    );

    $advertiser->p2p_order_cancel(id => $order->{id});
    is $client->p2p_order_info(id => $order->{id})->{payment_method_details}, undef,
        'payment_method_details not present in order_info for cancelled order';

    is exception { $client->p2p_advertiser_payment_methods(update => {$methods_by_tag{m1} => {is_enabled => 0, tag => 'test'}}) }, undef,
        'can disable and update method now';
    is exception { $client->p2p_advertiser_payment_methods(delete => [@methods_by_tag{qw/m1 m2/}]) }, undef, 'can delete methods';

};

subtest 'buy orders' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        type           => 'sell',
        payment_method => 'method3'
    );
    my $client  = BOM::Test::Helper::P2P::create_advertiser;
    my %methods = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            },
            {
                method => 'method1',
                tag    => 'm2'
            },
            {
                method => 'method2',
                tag    => 'm3'
            }])->%*;

    cmp_deeply(
        exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 10, payment_method_ids => [keys %methods]); },
        {error_code => 'OrderPaymentContactInfoNotAllowed'},
        'cannot provide payment_method_ids for buy order'
    );

    %methods = $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            },
            {
                method => 'method1',
                tag    => 'm2'
            },
            {
                method => 'method2',
                tag    => 'm3'
            }])->%*;
    my %methods_by_tag = map { $methods{$_}->{fields}{tag}{value} => $_ } keys %methods;
    $advertiser->p2p_advert_update(
        id                 => $advert->{id},
        payment_method_ids => [keys %methods]);

    is $client->p2p_advert_list(payment_method => ['method1'])->[0]{id}, $advert->{id}, 'search ad list by method';

    my $order = $client->p2p_order_create(
        advert_id => $advert->{id},
        amount    => 10
    );
    is $order->{payment_method},       undef, 'undef payment_method returned from order create';
    is $order->{payment_method_names}, undef, 'undef payment_method_names returned from order create';

    my $pm_details = {
        $methods_by_tag{m1} => $methods{$methods_by_tag{m1}},
        $methods_by_tag{m2} => $methods{$methods_by_tag{m2}},
        $methods_by_tag{m3} => $methods{$methods_by_tag{m3}},
    };

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details returned from order_create';

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details for order_create';
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details for order_info';

    $client->p2p_order_confirm(id => $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details,
        'payment_method_details returned when buyer-confirmed';

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details returned when timed-out';

    $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released'
    );
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details returned when disputed';

    cmp_deeply(exception { $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m1} => {is_enabled => 0}}) },
        undef, 'advertiser can disable payment method of ad with active order');

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_payment_methods(
                update => {
                    $methods_by_tag{m2} => {is_enabled => 0},
                    $methods_by_tag{m3} => {is_enabled => 0}})
        },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'advertiser cannnot disable all methods of ad with active order'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id             => $advert->{id},
                payment_method => 'method1,method2',
            )
        },
        {
            error_code => 'PaymentMethodParam',
        },
        'cannot set payment_method directly'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id                 => $advert->{id},
                payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m2}],
            )
        },
        {
            error_code     => 'PaymentMethodRemoveActiveOrders',
            message_params => ['Method 2']
        },
        'advertiser cannnot remove a payment method name from ad with active order'
    );

    $advertiser->p2p_order_confirm(id => $order->{id});
    is $client->p2p_order_info(id => $order->{id})->{payment_method_details}, undef, 'payment_method_details hidden when completed';

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_payment_methods(
                update => {
                    $methods_by_tag{m2} => {is_enabled => 0},
                    $methods_by_tag{m3} => {is_enabled => 0}})
        },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'advertiser cannot disable all methods of ad that is still active'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [$methods_by_tag{m1}]) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot set disabled payment method on active ad'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => []) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot remove all methods from active ad'
    );

    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_payment_methods(
                update => {
                    $methods_by_tag{m2} => {is_enabled => 0},
                    $methods_by_tag{m3} => {is_enabled => 0}})
        },
        undef,
        'advertiser can disable all methods of inactive ad'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [-1, $methods_by_tag{m2}]) },
        {
            error_code => 'InvalidPaymentMethods',
        },
        'cannot set non-existing payment method id on ad'
    );

    is undef, exception { $advert = $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => []) },
        'can set empty methods on inactve ad';
    is $advert->{payment_method_ids}, undef, 'payment_method_ids now undef';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1, payment_method_ids => [$methods_by_tag{m2}]) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot set disabled payment method when activating ad'
    );

    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [$methods_by_tag{m2}]) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot set disabled payment method on active ad'
    );
};

done_testing();

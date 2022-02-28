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
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::create_payment_methods();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_methods_enabled(1);

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
        rate_type          => 'fixed',
        contact_info       => 'call me',
        payment_method_ids => [keys %methods],
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment method names';
    cmp_deeply $advert->{payment_method_details}, \%methods, 'payment method details';

    is exception {
        %methods = $client->p2p_advertiser_payment_methods(
            update => {
                $methods_by_tag{m1} => {is_enabled => 0},
                $methods_by_tag{m2} => {is_enabled => 0}}
            )->%*
    }, undef, 'can disable methods';

    my $ad_info = $client->p2p_advert_info(id => $advert->{id});
    cmp_deeply $ad_info->{payment_method_names}, ['Method 2'], 'payment method names';
    cmp_deeply $ad_info->{payment_method_details}, \%methods, 'payment method details';

    my $otherclient = BOM::Test::Helper::P2P::create_advertiser;
    $ad_info = $otherclient->p2p_advert_info(id => $advert->{id});
    ok !exists $ad_info->{payment_method_details}, 'payment_method_details not returned for other client from p2p_advert_info';

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

    my $pm_details = {
        $methods_by_tag{m4} => $methods{$methods_by_tag{m4}},
        $methods_by_tag{m5} => $methods{$methods_by_tag{m5}},
    };
    cmp_deeply $update->{payment_method_details}, $pm_details, 'update payment method details';

    $update = $client->p2p_advert_update(id => $advert->{id});
    cmp_deeply $update->{payment_method_details}, $pm_details, 'empty update payment method details';

    is exception { $client->p2p_advertiser_payment_methods(delete => [$methods_by_tag{m3}]) }, undef, 'allowed to delete unused methods';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(delete => [@methods_by_tag{qw/m4 m5/}]) },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'cannot delete all methods from an ad'
    );

    is(
        exception {
            $advert = $client->p2p_advert_create(
                type                 => 'buy',
                amount               => 10,
                min_order_amount     => 1,
                max_order_amount     => 10,
                rate                 => 1,
                rate_type            => 'fixed',
                payment_method_names => ['method2', 'method1', 'method2'],
            )
        },
        undef,
        'can provide valid methods'
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment method for buy ad';

    cmp_deeply(
        exception {
            $client->p2p_advert_update(
                id                   => $advert->{id},
                payment_method_names => ['method1', 'method2', 'methodx'],
            )
        },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['methodx']
        },
        'cannot update with invalid method'
    );

    cmp_deeply $client->p2p_advert_update(
        id                   => $advert->{id},
        payment_method_names => ['method3', 'method1', 'method2']
    )->{payment_method_names}, ['Method 1', 'Method 2', 'Method 3'], 'can update with valid methods';

    $client->p2p_advert_update(
        id     => $advert->{id},
        delete => 1
    );    # so it's not picked up in following advert_list tests
};

subtest 'buy ads / sell orders' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;

    my %ad_params = (
        amount           => 100,
        description      => 'x',
        type             => 'buy',
        min_order_amount => 1,
        max_order_amount => 10,
        rate             => 1,
        rate_type        => 'fixed',
        local_currency   => 'myr',
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_create(%ad_params, payment_method_names => ['nonsense', 'method1']) },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['nonsense'],
        },
        'invalid pm name'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_create(%ad_params, payment_method_names => []) },
        {
            error_code => 'AdvertPaymentMethodRequired',
        },
        'no names'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_create(%ad_params, payment_method_names => ['method1'], payment_method => 'method1') },
        {
            error_code => 'AdvertPaymentMethodParam',
        },
        'cannot provide both payment_method_names and payment_method'
    );

    my $advert;
    is(exception { $advert = $advertiser->p2p_advert_create(%ad_params, payment_method_names => ['method2', 'method1']) },
        undef, 'can create ad with valid names');

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment_method_names returned from advert crate';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => []) },
        {
            error_code => 'AdvertPaymentMethodRequired',
        },
        'cannot update ad with empty payment_method_names'
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => ['method1', 'method3']) },
        undef, 'update ad method names');

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

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id          => $advert->{id},
                amount             => 10,
                contact_info       => 'x',
                payment_method_ids => [keys %methods],
                rule_engine        => $rule_engine
            )
        },
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
        payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m2}],
        rule_engine        => $rule_engine
    );
    is $order->{payment_method}, 'method1', 'order create payment_method';

    my $pm_details = {
        $methods_by_tag{m1} => $methods{$methods_by_tag{m1}},
        $methods_by_tag{m2} => $methods{$methods_by_tag{m2}},
    };

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details returned from order_create';

    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details,
        'payment_method_details returned from order_info for pending order';

    my $order_info = $advertiser->p2p_order_info(id => $order->{id});
    is $order_info->{payment_method}, 'method1', 'counterparty gets payment_method';
    cmp_deeply $order_info->{payment_method_details}, $pm_details, 'counterparty gets payment_method_details';

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

    $advertiser->p2p_advert_update(
        id     => $advert->{id},
        delete => 1
    );
};

subtest 'sell ads / buy orders' => sub {

    my %ad_params = (
        amount           => 100,
        description      => 'x',
        contact_info     => 'x',
        type             => 'sell',
        min_order_amount => 1,
        max_order_amount => 10,
        rate             => 1,
        rate_type        => 'fixed',
        local_currency   => 'myr',
    );

    my $advertiser         = BOM::Test::Helper::P2P::create_advertiser(balance => 100);
    my %advertiser_methods = $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1',
            },
            {
                method => 'method1',
                tag    => 'm2'
            },
            {
                method     => 'method2',
                tag        => 'm3',
                is_enabled => 0,
            }])->%*;
    my %methods_by_tag = map { $advertiser_methods{$_}->{fields}{tag}{value} => $_ } keys %advertiser_methods;

    my $advert;
    is(
        exception {
            $advert =
                $advertiser->p2p_advert_create(%ad_params, payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m2}, $methods_by_tag{m3}])
        },
        undef,
        'can create ad with valid methods',
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1'], 'payment_method_names correct on created ad';

    my $client = BOM::Test::Helper::P2P::create_advertiser;

    my %client_methods = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            }])->%*;

    cmp_deeply(
        exception {
            $client->p2p_order_create(
                advert_id          => $advert->{id},
                amount             => 10,
                payment_method_ids => [keys %client_methods],
                rule_engine        => $rule_engine
            )
        },
        {error_code => 'OrderPaymentContactInfoNotAllowed'},
        'cannot provide payment_method_ids for buy order'
    );

    is $client->p2p_advert_list(payment_method => ['method1'])->[0]{id}, $advert->{id}, 'search ad list by method';
    cmp_deeply $client->p2p_advert_list(payment_method => ['method2']), [], 'search ad list by disabled method';

    my $order = $client->p2p_order_create(
        advert_id   => $advert->{id},
        amount      => 10,
        rule_engine => $rule_engine,
    );

    my $pm_details = {
        $methods_by_tag{m1} => $advertiser_methods{$methods_by_tag{m1}},
        $methods_by_tag{m2} => $advertiser_methods{$methods_by_tag{m2}},
    };

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details returned from order_create';

    %advertiser_methods = $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m3} => {is_enabled => 1}})->%*;

    $pm_details->{$methods_by_tag{m3}} = $advertiser_methods{$methods_by_tag{m3}};

    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details for order_info';

    $client->p2p_order_confirm(id => $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details,
        'payment_method_details returned after buyer-confirmed';

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details returned when timed-out';

    $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released'
    );
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details, 'payment_method_details returned when disputed';

    cmp_deeply(exception { $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m1} => {is_enabled => 0}}) },
        undef, 'advertiser can disable payment method of ad with active order if it does not remove ad method names');

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m2} => {is_enabled => 0}})
        },
        {
            error_code     => 'PaymentMethodUsedByAd',
            message_params => [$advert->{id}]
        },
        'advertiser cannnot disable a method of ad with active order if it removes a ad method name'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advert_update(
                id                 => $advert->{id},
                payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m3}],
            )
        },
        {
            error_code     => 'PaymentMethodRemoveActiveOrders',
            message_params => ['Method 1']
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
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot reactivate ad with no active methods'
    );

    $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 0
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_ids => [-1, $methods_by_tag{m2}]) },
        {
            error_code => 'InvalidPaymentMethods',
        },
        'cannot set non-existing payment method id on inactive ad'
    );

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1, payment_method_ids => [$methods_by_tag{m2}]) },
        {
            error_code => 'ActivePaymentMethodRequired',
        },
        'cannot set disabled payment method when activating ad'
    );

    $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m2} => {is_enabled => 1}});

    is(exception { $advert = $advertiser->p2p_advert_update(id => $advert->{id}, is_active => 1, payment_method_ids => [$methods_by_tag{m2}]) },
        undef, 'can reactivate ad and set enabled method');

    cmp_deeply $advert->{payment_method_names}, ['Method 1'], 'payment_method_names returned from ad update';
};

subtest 'legacy buy ads' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser;

    my $ad = $advertiser->p2p_advert_create(
        amount           => 100,
        description      => 'x',
        type             => 'buy',
        min_order_amount => 1,
        max_order_amount => 10,
        rate             => 1,
        rate_type        => 'fixed',
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
    );

    $ad = $advertiser->p2p_advert_update(
        id                   => $ad->{id},
        payment_method_names => ['method1']);
    ok !$ad->{payment_method}, 'set payment_method_names clears payment method';
};

subtest 'legacy sell ads' => sub {

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    my $ad = $advertiser->p2p_advert_create(
        amount           => 100,
        description      => 'x',
        type             => 'sell',
        min_order_amount => 1,
        max_order_amount => 10,
        rate             => 1,
        rate_type        => 'fixed',
        local_currency   => 'myr',
        payment_method   => 'bank_transfer',
        payment_info     => 'legacy pm',
        contact_info     => 'x',
    );

    my ($method) = keys $advertiser->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1'
            }])->%*;
    $ad = $advertiser->p2p_advert_update(
        id                 => $ad->{id},
        payment_method_ids => [$method]);
    ok !$ad->{payment_method}, 'set payment_method_ids clears payment method';

};

done_testing();

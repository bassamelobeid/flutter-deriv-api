use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Test::Fatal;
use JSON::MaybeXS;
use P2P;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Config::Runtime;
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();
BOM::Test::Helper::P2PWithClient::create_payment_methods();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_methods_enabled(1);
$runtime_config->transaction_verification_countries([]);
$runtime_config->transaction_verification_countries_all(0);

subtest 'adverts' => sub {

    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 100);

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

    my $advert = P2P->new(client => $client)->p2p_advert_create(
        type               => 'sell',
        amount             => 10,
        min_order_amount   => 1,
        max_order_amount   => 10,
        rate               => 1,
        rate_type          => 'fixed',
        contact_info       => 'call me',
        payment_method_ids => [keys %methods],
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment method names from advert create';
    $_->{used_by_adverts} = [$advert->{id}] for (values %methods);
    cmp_deeply $advert->{payment_method_details}, \%methods, 'payment method details from advert create';

    $runtime_config->payment_method_countries($json->encode({method1 => {mode => 'include'}, method2 => {mode => 'exclude'}}));
    my $ad_info = $client->p2p_advert_info(id => $advert->{id});
    cmp_deeply $ad_info->{payment_method_names},                      ['Method 1', 'Method 2'], 'disabled pms shown in advert info to advert owner';
    cmp_deeply $client->p2p_advert_list()->[0]{payment_method_names}, ['Method 2'], 'disabled pms not shown in advert list to advert owner';
    cmp_deeply $ad_info->{payment_method_details},                    \%methods,    'payment method details when a method is disbled in country';

    BOM::Test::Helper::P2PWithClient::create_payment_methods();    # reset

    is exception {
        %methods = $client->p2p_advertiser_payment_methods(
            update => {
                $methods_by_tag{m1} => {is_enabled => 0},
                $methods_by_tag{m2} => {is_enabled => 0}}
        )->%*
    }, undef, 'can disable methods';

    $ad_info = $client->p2p_advert_info(id => $advert->{id});
    cmp_deeply $ad_info->{payment_method_names},   ['Method 2'], 'payment method names';
    cmp_deeply $ad_info->{payment_method_details}, \%methods,    'payment method details';

    my $otherclient = BOM::Test::Helper::P2PWithClient::create_advertiser;
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

    $methods{$methods_by_tag{$_}}->{used_by_adverts} = [$advert->{id}] for qw/m4 m5/;

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
            $advert = P2P->new(client => $client)->p2p_advert_create(
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
        'can provide valid method names for buy ad'
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment method for buy ad';

    $runtime_config->payment_method_countries($json->encode({method1 => {mode => 'include'}}));
    cmp_deeply $client->p2p_advert_info(id => $advert->{id})->{payment_method_names}, ['Method 1', 'Method 2'],
        'payment method names when a method is disbled in country';
    BOM::Test::Helper::P2PWithClient::create_payment_methods();    # reset

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

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser;

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
        exception { P2P->new(client => $advertiser)->p2p_advert_create(%ad_params, payment_method_names => ['nonsense', 'method1']) },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['nonsense'],
        },
        'invalid pm name'
    );

    cmp_deeply(
        exception { P2P->new(client => $advertiser)->p2p_advert_create(%ad_params, payment_method_names => []) },
        {
            error_code => 'AdvertPaymentMethodRequired',
        },
        'no names'
    );

    cmp_deeply(
        exception { P2P->new(client => $advertiser)->p2p_advert_create(%ad_params, payment_method_names => ['method1'], payment_method => 'method1') }
        ,
        {
            error_code => 'AdvertPaymentMethodParam',
        },
        'cannot provide both payment_method_names and payment_method'
    );

    my $advert;
    is(exception { $advert = P2P->new(client => $advertiser)->p2p_advert_create(%ad_params, payment_method_names => ['method2', 'method1']) },
        undef, 'can create ad with valid names');

    cmp_deeply $advert->{payment_method_names}, ['Method 1', 'Method 2'], 'payment_method_names returned from advert create';

    cmp_deeply(
        exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => []) },
        {
            error_code => 'AdvertPaymentMethodRequired',
        },
        'cannot update ad with empty payment_method_names'
    );

    is(exception { $advertiser->p2p_advert_update(id => $advert->{id}, payment_method_names => ['method1', 'method3']) },
        undef, 'update ad method names');

    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 100);

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
        $methods_by_tag{m1} => {
            $methods{$methods_by_tag{m1}}->%*,
            used_by_orders  => [$order->{id}],
            used_by_adverts => undef
        },
        $methods_by_tag{m2} => {
            $methods{$methods_by_tag{m2}}->%*,
            used_by_orders  => [$order->{id}],
            used_by_adverts => undef
        },
    };

    cmp_deeply $order->{payment_method_details}, $pm_details, 'payment_method_details returned from order_create';

    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, $pm_details,
        'payment_method_details returned from order_info for pending order';

    delete $pm_details->{$methods_by_tag{m1}}->@{qw/used_by_orders used_by_adverts/};
    delete $pm_details->{$methods_by_tag{m2}}->@{qw/used_by_orders used_by_adverts/};

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

    my $advertiser         = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 100);
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
                P2P->new(client => $advertiser)
                ->p2p_advert_create(%ad_params, payment_method_ids => [$methods_by_tag{m1}, $methods_by_tag{m2}, $methods_by_tag{m3}])
        },
        undef,
        'can create ad with valid methods',
    );

    cmp_deeply $advert->{payment_method_names}, ['Method 1'], 'payment_method_names correct on created ad';

    my $client = BOM::Test::Helper::P2PWithClient::create_advertiser;

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

    %advertiser_methods = $advertiser->p2p_advertiser_payment_methods()->%*;

    my %pm_details = (
        $methods_by_tag{m1} => $advertiser_methods{$methods_by_tag{m1}},
        $methods_by_tag{m2} => $advertiser_methods{$methods_by_tag{m2}},
    );

    cmp_deeply $advertiser->p2p_order_info(id => $order->{id})->{payment_method_details}, \%pm_details,
        'advertiser gets all pm detail fields in order';

    delete $pm_details{$_}->@{qw/used_by_adverts used_by_orders/} for keys %pm_details;
    cmp_deeply $order->{payment_method_details}, \%pm_details, 'payment_method_details returned from order_create (minus some fields)';

    %advertiser_methods = $advertiser->p2p_advertiser_payment_methods(update => {$methods_by_tag{m3} => {is_enabled => 1}})->%*;

    $pm_details{$methods_by_tag{m3}} = $advertiser_methods{$methods_by_tag{m3}};
    delete $pm_details{$methods_by_tag{m3}}->@{qw/used_by_adverts used_by_orders/};

    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, \%pm_details, 'payment_method_details for order_info';

    $client->p2p_order_confirm(id => $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, \%pm_details,
        'payment_method_details returned after buyer-confirmed';

    BOM::Test::Helper::P2PWithClient::set_order_disputable($client, $order->{id});
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, \%pm_details, 'payment_method_details returned when timed-out';

    $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released'
    );
    cmp_deeply $client->p2p_order_info(id => $order->{id})->{payment_method_details}, \%pm_details, 'payment_method_details returned when disputed';

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

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser;

    my $ad = P2P->new(client => $advertiser)->p2p_advert_create(
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

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 100);

    my $ad = P2P->new(client => $advertiser)->p2p_advert_create(
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

subtest 'cross border ads' => sub {
    $runtime_config->payment_method_countries(
        $json->encode({
                method1 => {
                    mode      => 'include',
                    countries => ['ng', 'za']
                },
                method2 => {
                    mode      => 'include',
                    countries => ['ng', 'za']
                },
                method3 => {
                    mode      => 'include',
                    countries => ['ng', 'za']}}));

    my $client_ng = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 1000,
        client_details => {residence => 'ng'});
    my $client_za = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 1000,
        client_details => {residence => 'za'});

    my %methods = $client_ng->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                tag    => 'm1',
            },
            {
                method => 'method2',
                tag    => 'm2',
            },
            {
                method => 'method3',
                tag    => 'm3',
            }])->%*;

    my %method_ids = map { $methods{$_}->{fields}{tag}{value} => $_ } keys %methods;

    my (undef, $ad_ng) = BOM::Test::Helper::P2P::create_advert(
        client             => P2P->new(client => $client_ng),
        type               => 'sell',
        payment_method_ids => [keys %methods]);

    my (undef, $ad_za) = BOM::Test::Helper::P2P::create_advert(
        client               => P2P->new(client => $client_za),
        type                 => 'buy',
        payment_method_names => ['method1', 'method2', 'method3']);

    $runtime_config->payment_method_countries(
        $json->encode({
                method1 => {
                    mode      => 'include',
                    countries => ['ng']
                },
                method2 => {
                    mode      => 'include',
                    countries => ['za']
                },
                method3 => {
                    mode      => 'include',
                    countries => []}}));

    my $ads = $client_za->p2p_advert_list(local_currency => 'NGN');
    ok !@$ads, 'sell ad not returned from advert_list when no compatible pms';

    $ads = $client_ng->p2p_advert_list(local_currency => 'ZAR');
    ok !@$ads, 'no buy ad not returned from advert_list when no compatible pms';

    cmp_deeply(
        $client_ng->p2p_advert_info(id => $ad_ng->{id})->{payment_method_names},
        ['Method 1', 'Method 2', 'Method 3'],
        'ad owner sees disabled sell ad pms in advert info'
    );

    is $client_za->p2p_advert_info(id => $ad_ng->{id})->{payment_method_names}, undef,
        'other client does not see disabled sell ad pms in advert info';

    cmp_deeply(
        $client_za->p2p_advert_info(id => $ad_za->{id})->{payment_method_names},
        ['Method 1', 'Method 2', 'Method 3'],
        'ad owner sees disabled buy ad pms in advert info'
    );

    is $client_ng->p2p_advert_info(id => $ad_za->{id})->{payment_method_names}, undef, 'other client does not see disabled buy ad pms in advert info';

    cmp_deeply(
        exception { $client_ng->p2p_order_create(advert_id => $ad_za->{id}, amount => 1, rule_engine => $rule_engine) },
        {error_code => 'AdvertNotFound'},
        'canot place order on buy ad with no compatible pms'
    );

    cmp_deeply(
        exception { $client_za->p2p_order_create(advert_id => $ad_ng->{id}, amount => 1, rule_engine => $rule_engine) },
        {error_code => 'AdvertNotFound'},
        'canot place order on sell ad with no compatible pms'
    );

    $runtime_config->payment_method_countries(
        $json->encode({
                method1 => {
                    mode      => 'include',
                    countries => ['ng']
                },
                method2 => {
                    mode      => 'include',
                    countries => ['za']
                },
                method3 => {
                    mode      => 'include',
                    countries => ['ng', 'za']}}));

    cmp_deeply(
        exception { $client_ng->p2p_advert_list(local_currency => 'XXX') },
        {error_code => 'InvalidLocalCurrency'},
        'cannot search by invalid local currency'
    );

    $ads = $client_za->p2p_advert_list(local_currency => 'NGN');
    cmp_deeply([map { $_->{id} } @$ads],        [$ad_ng->{id}], 'sell ad with partial matching pms returned when search by local currency');
    cmp_deeply($ads->[0]{payment_method_names}, ['Method 3'],   'invalid pms filtered out');

    $ads = $client_ng->p2p_advert_list(local_currency => 'ZAR');
    cmp_deeply([map { $_->{id} } @$ads],        [$ad_za->{id}], 'buy ad with partial matching pms returned when search by local currency');
    cmp_deeply($ads->[0]{payment_method_names}, ['Method 3'],   'invalid pms filtered out');

    $ads = $client_za->p2p_advert_list(
        local_currency => 'NGN',
        payment_method => ['method1', 'method2']);
    ok !@$ads, 'cannot retrieve sell ad by searching for invalid pms';

    $ads = $client_ng->p2p_advert_list(
        local_currency => 'ZAR',
        payment_method => ['method1', 'method2']);
    ok !@$ads, 'cannot retrieve buy ad by searching for invalid pms';

    cmp_deeply(
        $client_ng->p2p_advert_info(id => $ad_ng->{id})->{payment_method_names},
        ['Method 1', 'Method 2', 'Method 3'],
        'ad owner sees disabled sell ad pms in advert info'
    );

    cmp_deeply($client_za->p2p_advert_info(id => $ad_ng->{id})->{payment_method_names},
        ['Method 3'], 'other client does not see disabled sell ad pms in advert info');

    cmp_deeply(
        $client_za->p2p_advert_info(id => $ad_za->{id})->{payment_method_names},
        ['Method 1', 'Method 2', 'Method 3'],
        'ad owner sees disabled buy ad pms in advert info'
    );

    cmp_deeply($client_ng->p2p_advert_info(id => $ad_za->{id})->{payment_method_names},
        ['Method 3'], 'other client does not see disabled buy ad pms in advert info');

    my %params = (
        advert_id    => $ad_za->{id},
        amount       => 1,
        rule_engine  => $rule_engine,
        contact_info => 'x'
    );

    cmp_deeply(
        exception { $client_ng->p2p_order_create(%params, payment_method_ids => [$method_ids{m1}]) },
        {
            error_code     => 'PaymentMethodNotInAd',
            message_params => ['Method 1']
        },
        'cannot order from ad when pm id disabled in my country'
    );
    cmp_deeply(
        explain exception { $client_ng->p2p_order_create(%params, payment_method_ids => [$method_ids{m2}]) },
        {
            error_code     => 'PaymentMethodNotInAd',
            message_params => ['Method 2']
        },
        'cannot order from ad when pm id disabled in advertisers country'
    );

    is(exception { $client_ng->p2p_order_create(%params, payment_method_ids => [$method_ids{m3}]) },
        undef, 'can create an sell order when pm is enabled in both countries');

    my $order;
    is(exception { $order = $client_za->p2p_order_create(advert_id => $ad_ng->{id}, amount => 1, rule_engine => $rule_engine) },
        undef, 'can create buy order when pm is enabled in both countries');

    cmp_deeply([keys $order->{payment_method_details}->%*], [$method_ids{m3}], 'only enabled pm is returned in order details');

};

subtest 'ads visiblity to non-P2P clients' => sub {

    my $client_id = BOM::Test::Helper::Client::create_client();
    $client_id->account('USD');
    $client_id->residence('id');

    $runtime_config->payment_method_countries(
        $json->encode({
                method4 => {
                    mode      => 'include',
                    countries => ['id']
                },
                method5 => {
                    mode      => 'include',
                    countries => ['br']}}));

    my $advertiser_id = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 1000,
        client_details => {residence => 'id'});

    my $advertiser_br = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 1000,
        client_details => {residence => 'br'});

    my (undef, $legacy_ad) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser_id),
        amount           => 5,
        min_order_amount => 2,
        max_order_amount => 5,
        type             => 'buy'
    );

    my $ads = $client_id->p2p_advert_list();
    cmp_deeply([map { $_->{id} } @$ads], [$legacy_ad->{id}], 'legacy ad visible to non-p2p user due to matching local currency');

    my (undef, $ad_id) = BOM::Test::Helper::P2P::create_advert(
        client               => P2P->new(client => $advertiser_id),
        amount               => 10,
        min_order_amount     => 8,
        max_order_amount     => 10,
        type                 => 'buy',
        rate                 => 2,
        payment_method_names => ['method4']);

    my (undef, $ad_br) = BOM::Test::Helper::P2P::create_advert(
        client               => P2P->new(client => $advertiser_br),
        type                 => 'buy',
        payment_method_names => ['method5']);

    $ads = $client_id->p2p_advert_list();

    cmp_deeply(
        [map { $_->{id} } $ads->@*],
        bag($legacy_ad->{id}, $ad_id->{id}),
        'non-P2P client can also view local ads in indonesia due to matching payment methods.'
    );

    $ads = $client_id->p2p_advert_list(payment_method => ['method4']);

    cmp_deeply([map { $_->{id} } $ads->@*], [$ad_id->{id}], 'legacy ads not visible due to added filter for payment_method');

    is $client_id->p2p_advert_list(payment_method => ['method5'])->@*, 0, 'No ads returned because no match for payment method';

    is $client_id->p2p_advert_list(local_currency => 'BRL')->@*, 0, 'No ads returned because no match between payment method in BRL and ID';

    $runtime_config->payment_method_countries(
        $json->encode({
                method4 => {
                    mode      => 'include',
                    countries => ['id']
                },
                method5 => {
                    mode      => 'include',
                    countries => ['br', 'id']}}));

    $ads = $client_id->p2p_advert_list(local_currency => 'BRL');

    cmp_deeply([map { $_->{id} } $ads->@*],
        [$ad_br->{id}], "non-P2P client can also see ads from Brazil since method 5 is now available client's residence: Indonesia");

};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Guard;
use JSON::MaybeXS;
use List::Util qw(first);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
my $json = JSON::MaybeXS->new;

my $client_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com'
});
$client_escrow->account('USD');

# We need to restore previous values when tests is done
my %init_config_values = (
    'system.suspend.p2p'                    => $app_config->system->suspend->p2p,
    'payments.p2p.enabled'                  => $app_config->payments->p2p->enabled,
    'payments.p2p.available'                => $app_config->payments->p2p->available,
    'payments.p2p.escrow'                   => $app_config->payments->p2p->escrow,
    'payments.p2p.payment_method_countries' => $app_config->payments->p2p->payment_method_countries,
);

$app_config->set({'system.suspend.p2p'     => 0});
$app_config->set({'payments.p2p.enabled'   => 1});
$app_config->set({'payments.p2p.available' => 1});
$app_config->set({'payments.p2p.escrow'    => [$client_escrow->loginid]});
$app_config->set({
        'payments.p2p.payment_method_countries' => $json->encode({
                bank_transfer => {mode => 'exclude'},
                other         => {mode => 'exclude'}})});

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

my $t = build_wsapi_test();

BOM::Test::Helper::P2P::bypass_sendbird();

subtest 'sell ads' => sub {

    my $advertiser       = BOM::Test::Helper::P2P::create_advertiser(balance => 1000);
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
    $t->await::authorize({authorize => $advertiser_token});

    my $resp = $t->await::p2p_payment_methods({p2p_payment_methods => 1});
    test_schema('p2p_payment_methods', $resp);

    $resp = $t->await::p2p_advertiser_payment_methods({
            p2p_advertiser_payment_methods => 1,
            create => [{
                method    => 'bank_transfer',
                bank_name => 'maybank',
                branch    => '001',
                account   => '1234',
    }]});
    test_schema('p2p_advertiser_payment_methods', $resp);
    my $method = $resp->{p2p_advertiser_payment_methods};
    my ($method_id) = keys $method->%*;

    $resp = $t->await::p2p_advert_create({
        p2p_advert_create  => 1,
        type               => 'sell',
        amount             => 100,
        local_currency     => 'IDR',
        rate               => 1,
        min_order_amount   => 0.1,
        max_order_amount   => 10,
        contact_info       => 'call me',
        payment_method_ids => [$method_id],
    });
    test_schema('p2p_advert_create', $resp);
    my $advert = $resp->{p2p_advert_create};
    cmp_deeply $advert->{payment_method_details}, $method, 'payment method details from advert create';

    $resp = $t->await::p2p_advert_info({
        p2p_advert_info => 1,
        id              => $advert->{id},
    });
    cmp_deeply $advert->{payment_method_details}, $method, 'payment method details from advert info';

    my $client       = BOM::Test::Helper::P2P::create_advertiser;
    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test', ['payments']);
    $t->await::authorize({authorize => $client_token});

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list => 1,
        payment_method  => ['bank_transfer', 'other'],
    });
    is $resp->{p2p_advert_list}{list}[0]{id}, $advert->{id}, 'search ads by payment methods';
    cmp_deeply $resp->{p2p_advert_list}{list}[0]{payment_method_names}, ['Bank Transfer'], 'payment method names in advert list';

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $advert->{id},
        amount           => 10,
    });
    test_schema('p2p_order_create', $resp);
    my $order = $resp->{p2p_order_create};

    cmp_deeply $order->{payment_method_details}, $method, 'got method details in from order_create';

    $t->await::authorize({authorize => $advertiser_token});

    $resp = $t->await::p2p_advertiser_payment_methods({
            p2p_advertiser_payment_methods => 1,
            create => [{
                method    => 'bank_transfer',
                bank_name => 'hsbc',
                branch    => '002',
                account   => '4321',
            }]});
    $method = $resp->{p2p_advertiser_payment_methods};
    $method_id = first { $resp->{p2p_advertiser_payment_methods}{$_}{fields}{bank_name}{value} eq 'hsbc' } keys $method->%*;

    $resp = $t->await::p2p_advert_update({
            p2p_advert_update  => 1,
            id                 => $advert->{id},
            payment_method_ids => [$method_id]});

    test_schema('p2p_advert_update', $resp);

    $t->await::authorize({authorize => $client_token});
    
    $resp = $t->await::p2p_advert_info({
        p2p_advert_info  => 1,
        id               => $advert->{id}
    });
    cmp_deeply $resp->{p2p_advert_info}{payment_method_names}, ['Bank Transfer'], 'payment method names for client';

    $resp = $t->await::p2p_order_info({
        p2p_order_info => 1,
        id             => $order->{id},
    });
    cmp_deeply $resp->{p2p_order_info}{payment_method_details}, { $method_id => $method->{$method_id} }, 'method details updated for client';

    $t->await::p2p_order_confirm({
        p2p_order_confirm => 1,
        id                => $order->{id},
    });

    $t->await::authorize({authorize => $advertiser_token});
    $t->await::p2p_order_confirm({
        p2p_order_confirm => 1,
        id                => $order->{id},
    });

    $resp = $t->await::p2p_order_info({
        p2p_order_info => 1,
        id             => $order->{id},
    });
    ok $resp->{p2p_order_info}{id} eq $order->{id}, 'sanity check order_info on completed order';

    $resp = $t->await::p2p_advert_update({
        p2p_advert_update => 1,
        id                => $advert->{id},
        is_active         => 0,
    });

    $resp = $t->await::p2p_advertiser_payment_methods({
            p2p_advertiser_payment_methods => 1,
            update                         => {
                $method_id => {
                    is_enabled => 0,
                    branch     => ''
                }
            },
        });
    is $resp->{p2p_advertiser_payment_methods}{$method_id}{is_enabled}, 0, 'update method ok';

    $resp = $t->await::p2p_advertiser_payment_methods({
        p2p_advertiser_payment_methods => 1,
        delete                         => [$method_id],
    });
    ok keys $resp->{p2p_advertiser_payment_methods}->%* == 1, 'delete method ok';
};

subtest 'sell orders' => sub {

    my $advertiser       = BOM::Test::Helper::P2P::create_advertiser;
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
    $t->await::authorize({authorize => $advertiser_token});

    my $resp = $t->await::p2p_advert_create({
        p2p_advert_create => 1,
        type              => 'buy',
        amount            => 100,
        local_currency    => 'IDR',
        rate              => 1,
        min_order_amount  => 0.1,
        max_order_amount  => 10,
        payment_method    => 'bank_transfer',
    });
    my $advert = $resp->{p2p_advert_create};

    $resp = $t->await::p2p_advert_update({
        p2p_advert_update => 1,
        id                => $advert->{id},
        payment_method    => 'other,bank_transfer',
    });
    is $resp->{p2p_advert_update}{payment_method}, 'bank_transfer,other', 'update ad payment_method';

    $resp = $t->await::p2p_advert_info({
        p2p_advert_info => 1,
        id              => $advert->{id},
    });
    is $resp->{p2p_advert_info}{payment_method}, 'bank_transfer,other', 'ad info payment_method';

    my $client       = BOM::Test::Helper::P2P::create_advertiser(balance => 1000);
    my $client_token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test', ['payments']);
    $t->await::authorize({authorize => $client_token});

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list => 1,
        payment_method  => ['other'],
    });
    is $resp->{p2p_advert_list}{list}[0]{id}, $advert->{id}, 'search ads by payment method';

    $resp = $t->await::p2p_advertiser_payment_methods({
            p2p_advertiser_payment_methods => 1,
            create                         => [{
        method    => 'bank_transfer',
        bank_name => 'cimb',
        branch    => '001',
        account   => '1234',
    }]});
    
    my $method = $resp->{p2p_advertiser_payment_methods};
    my ($method_id) = keys $method->%*;

    $resp = $t->await::p2p_order_create({
        p2p_order_create   => 1,
        advert_id          => $advert->{id},
        amount             => 10,
        contact_info       => 'call me ',
        payment_method_ids => [$method_id],
    });
    test_schema('p2p_order_create', $resp);
    my $order = $resp->{p2p_order_create};
    cmp_deeply $order->{payment_method_details}, $method, 'got method details in from order_create';

    $resp = $t->await::p2p_order_list({
        p2p_order_list   => 1,
    });
    
    cmp_deeply $resp->{p2p_order_list}{list}[0]{payment_method_names}, ['Bank Transfer'], 'payment method names in order list';
    
    $t->await::authorize({authorize => $advertiser_token});

    $resp = $t->await::p2p_order_info({
        p2p_order_info => 1,
        id             => $order->{id},
    });
    cmp_deeply $resp->{p2p_order_info}{payment_method_details}, $method, 'counterparty sees payment details';

};

$t->finish_ok;

done_testing();

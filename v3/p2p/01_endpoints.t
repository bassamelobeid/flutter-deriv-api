use strict;
use warnings;
use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw(top_up);
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::User::Client;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Guard;

cleanup_redis_tokens();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

# We need to restore previous values when tests is done
my %init_config_values = (
    'payments.p2p.enabled'                 => $app_config->payments->p2p->enabled,
    'system.suspend.p2p'                   => $app_config->system->suspend->p2p,
    'payments.p2p.available'               => $app_config->payments->p2p->available,
    'payments.p2p.available_for_countries' => $app_config->payments->p2p->available_for_countries,
    'payments.p2p.available_for_currencies' => $app_config->payments->p2p->available_for_countries,
    'payments.p2p.limits.maximum_order'    => $app_config->payments->p2p->limits->maximum_order,
);

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

$app_config->set({'payments.p2p.enabled'                 => 1});
$app_config->set({'system.suspend.p2p'                   => 0});
$app_config->set({'payments.p2p.available'               => 1});
$app_config->set({'payments.p2p.available_for_countries' => ['id']});
$app_config->set({'payments.p2p.available_for_currencies' => ['usd']});
$app_config->set({'payments.p2p.limits.maximum_order'    => 10});

my $t = build_wsapi_test();

my $email_advertiser = 'p2p_advertiser@test.com';
my $email_client     = 'p2p_client@test.com';

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email_advertiser
});

my $user_advertiser = BOM::User->create(
    email    => $email_advertiser,
    password => 'test'
);
$user_advertiser->update_email_fields(email_verified => 't');
$user_advertiser->add_client($client_vr);

my $client_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_client
});

my $user_client = BOM::User->create(
    email    => $email_client,
    password => 'test'
);
$user_client->add_client($client_client);
$client_client->account('USD');

my $client_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com'
});
$client_escrow->account('USD');
$app_config->set({'payments.p2p.escrow' => [$client_escrow->loginid]});

my %advertiser_params = map { $_ => rand(999) } qw( name contact_info default_advert_description payment_info );

my %advert_params = (
    amount           => 100,
    description      => 'Test advert',
    local_currency   => 'IDR',
    max_order_amount => 10,
    min_order_amount => 0.1,
    payment_method   => 'bank_transfer',
    rate             => 1,
    type             => 'sell',
    payment_info     => 'ad pay info',
    contact_info     => 'ad contact info'
);

my ($resp, $token_vr, $client_advertiser, $token_advertiser, $token_client, $advertiser, $advert, $order);

subtest 'new real account for p2p' => sub {
    my %account_params = (
        new_account_real       => 1,
        account_opening_reason => 'Peer-to-peer exchange',
        last_name              => 'last-name',
        first_name             => 'first\'name',
        date_of_birth          => '1990-12-30',
        residence              => 'id',
    );

    $token_vr = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token', ['admin']);
    $t->await::authorize({authorize => $token_vr});
    $resp = $t->await::new_account_real(\%account_params);
    test_schema('new_account_real', $resp);
    my $loginid = $resp->{new_account_real}->{client_id};
    like($loginid, qr/^CR\d+$/, "got CR client $loginid");
    $client_advertiser = BOM::User::Client->new({loginid => $loginid});
    top_up($client_advertiser, $client_advertiser->currency, 1000);
};

subtest 'misc' => sub {
    $token_vr = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');
    $t->await::authorize({authorize => $token_vr});
    $resp = $t->await::p2p_advert_list({p2p_advert_list => 1})->{error};
    ok $resp->{code} eq 'PermissionDenied' && $resp->{message} =~ /requires payments scope/, 'Payments scope required';

    $token_vr = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $token_vr});
    $resp = $t->await::p2p_advert_list({p2p_advert_list => 1})->{error};
    is $resp->{code}, 'UnavailableOnVirtual', 'VR not allowed';

    $token_client = BOM::Platform::Token::API->new->create_token($client_client->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $token_client});
    $resp = $t->await::p2p_advert_list({p2p_advert_list => 1})->{p2p_advert_list}{list};
    ok ref $resp eq 'ARRAY' && $resp->@* == 0, 'Client gets empty advert list';
};

subtest 'create advertiser' => sub {
    $token_advertiser = BOM::Platform::Token::API->new->create_token($client_advertiser->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $token_advertiser});
    $resp = $t->await::p2p_advertiser_info({p2p_advertiser_info => 1})->{error};
    is $resp->{code}, 'AdvertiserNotFound', 'Advertiser not yet registered';

    $resp = $t->await::p2p_advertiser_create({
        p2p_advertiser_create => 1,
        %advertiser_params
    });
    test_schema('p2p_advertiser_create', $resp);
    $advertiser = $resp->{p2p_advertiser_create};

    is $advertiser->{$_}, $advertiser_params{$_}, "advertiser $_" for qw( name contact_info default_advert_description payment_info );
    ok $advertiser->{id} > 0, 'advertiser id';
    ok !$advertiser->{is_approved}, 'advertiser not approved';
    ok $advertiser->{is_listed}, "advertiser's adverts are listed";

    $resp = $t->await::p2p_advertiser_info({p2p_advertiser_info => 1});
    test_schema('p2p_advertiser_info', $resp);

    cmp_deeply($resp->{p2p_advertiser_info}, $advertiser, 'advertiser info is correct');

    $resp = $t->await::p2p_advertiser_create({
            p2p_advertiser_create => 1,
            %advertiser_params
        })->{error};
    is $resp->{code}, 'AlreadyRegistered', 'Cannot create duplicate advertiser';

    $resp = $t->await::p2p_advert_create({
            p2p_advert_create => 1,
            %advert_params
        })->{error};
    is $resp->{code}, 'AdvertiserNotApproved', 'Unapproved advertiser cannot create ad';
};

subtest 'update advertiser' => sub {
    $token_advertiser = BOM::Platform::Token::API->new->create_token($client_advertiser->loginid, 'test token', ['payments']);
    $t->await::authorize({authorize => $token_advertiser});

    my ($name, $payment, $contact) = ('new advertiser name', 'adv pay info', 'adv contact info');

    $resp = $t->await::p2p_advertiser_update({
            p2p_advertiser_update => 1,
            name                  => $name,
        })->{error};
    is $resp->{code}, 'AdvertiserNotApproved', 'Not approved advertiser cannot update the information';

    $client_advertiser->p2p_advertiser_update(is_approved => 1);

    $resp = $t->await::p2p_advertiser_update({
            p2p_advertiser_update => 1,
            name                  => ' ',
        })->{error};
    ok $resp->{code} eq 'InputValidationFailed' && $resp->{message} =~ /name/, 'Advertiser name cannot be blank';

    $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update      => 1,
        contact_info               => '',
        default_advert_description => '',
        payment_info               => '',
    });
    test_schema('p2p_advertiser_update', $resp);
    $advertiser = $resp->{p2p_advertiser_update};
    is $advertiser->{contact_info},               '', 'contact_info can be empty';
    is $advertiser->{default_advert_description}, '', 'default_advert_description can be empty';
    is $advertiser->{payment_info},               '', 'payment_info can be empty';

    $advertiser = $t->await::p2p_advertiser_update({
            p2p_advertiser_update => 1,
            is_listed             => 0,
            name                  => $name,
            payment_info          => $payment,
            contact_info          => $contact
        })->{p2p_advertiser_update};
    ok !$advertiser->{is_listed}, "is_listed updated";
    is $advertiser->{name},         $name,    'advertiser name updated';
    is $advertiser->{payment_info}, $payment, 'advertiser payment_info updated';
    is $advertiser->{contact_info}, $contact, 'advertiser contact_info updated';

    $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update => 1,
        is_listed             => 1,
    });
    test_schema('p2p_advertiser_update', $resp);
    $advertiser = $resp->{p2p_advertiser_update};
    ok $advertiser->{is_listed}, "enable is_listed";

    subtest 'Client use p2p_advertiser_info' => sub {
        $t->await::authorize({authorize => $token_client});
        $resp = $t->await::p2p_advertiser_info({
                p2p_advertiser_info => 1,
                id                  => $advertiser->{id}});
        test_schema('p2p_advertiser_info', $resp);
    };

};

subtest 'create advert (sell)' => sub {
    $t->await::authorize({authorize => $token_advertiser});

    $client_advertiser->p2p_advertiser_update(is_approved => 1);
    $resp = $t->await::p2p_advert_create({
        p2p_advert_create => 1,
        %advert_params
    });
    test_schema('p2p_advert_create', $resp);
    $advert = $resp->{p2p_advert_create};

    is $advert->{account_currency}, $client_advertiser->account->currency_code, 'account currency';
    is $advert->{advertiser_details}{id}, $advertiser->{id}, 'advertiser id';
    ok $advert->{amount} == $advert_params{amount}           && $advert->{amount_display} == $advert_params{amount},           'amount';
    ok $advert->{remaining_amount} == $advert_params{amount} && $advert->{remaining_amount_display} == $advert_params{amount}, 'remaining';
    is $advert->{country}, $client_advertiser->residence, 'country';
    is $advert->{description}, $advert_params{description}, 'description';
    ok $advert->{id} > 0, 'advert id';
    ok $advert->{is_active}, 'is active';
    is $advert->{local_currency}, $advert_params{local_currency}, 'local currency';
    ok $advert->{max_order_amount} == $advert_params{max_order_amount} && $advert->{max_order_amount_display} == $advert_params{max_order_amount},
        'max amount';
    ok $advert->{price} == $advert_params{rate} && $advert->{price_display} == $advert_params{rate}, 'price';
    ok $advert->{rate} == $advert_params{rate}  && $advert->{rate_display} == $advert_params{rate},  'rate';
    is $advert->{type},         $advert_params{type},         'type';
    is $advert->{payment_info}, $advert_params{payment_info}, 'payment_info';
    is $advert->{contact_info}, $advert_params{contact_info}, 'contact_info';

    $resp = $t->await::p2p_advertiser_adverts({p2p_advertiser_adverts => 1});
    test_schema('p2p_advertiser_adverts', $resp);
    cmp_deeply($resp->{p2p_advertiser_adverts}{list}[0], $advert, 'Advertiser adverts item matches advert create');

    # These fields are not returned from advert_create and advertiser_adverts, but should be returned from following calls
    $advert->{min_order_amount_limit} = $advert->{min_order_amount_limit_display} = num($advert_params{min_order_amount});
    $advert->{max_order_amount_limit} = $advert->{max_order_amount_limit_display} = num($advert_params{max_order_amount});

    $resp = $t->await::p2p_advert_list({p2p_advert_list => 1});
    test_schema('p2p_advert_list', $resp);
    cmp_deeply($resp->{p2p_advert_list}{list}[0], $advert, 'Advert list item matches advert create');

    $resp = $t->await::p2p_advert_info({
            p2p_advert_info => 1,
            id              => $advert->{id}});
    test_schema('p2p_advert_info', $resp);
    cmp_deeply($resp->{p2p_advert_info}, $advert, 'Advert info matches advert create');

    $t->await::authorize({authorize => $token_client});

    subtest 'Client use p2p_advert_info' => sub {
        $t->await::authorize({authorize => $token_client});
        $resp = $t->await::p2p_advert_info({
                p2p_advert_info => 1,
                id              => $advert->{id}});
        test_schema('p2p_advert_info', $resp);

        my %expected = %$advert;
        # Fields that should only be visible to advert owner
        delete @expected{
            qw( amount amount_display max_order_amount max_order_amount_display min_order_amount min_order_amount_display remaining_amount remaining_amount_display payment_info contact_info)
        };
        cmp_deeply($resp->{p2p_advert_info}, \%expected, 'Advert info sensitive fields hidden');

    };
};

subtest 'create order (buy)' => sub {
    my $amount = 10;
    my $price  = $advert->{price} * $amount;

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $advert->{id},
        amount           => $amount
    });
    test_schema('p2p_order_create', $resp);
    $order = $resp->{p2p_order_create};
    is $order->{account_currency}, $client_advertiser->account->currency_code, 'account currency';
    is $order->{advertiser_details}{id}, $advertiser->{id}, 'advertiser id';
    is $order->{advertiser_details}{name}, 'new advertiser name', 'advertiser name';
    ok $order->{amount} == $amount && $order->{amount_display} == $amount, 'amount';
    ok $order->{expiry_time}, 'expiry time';
    is $order->{local_currency}, $advert_params{local_currency}, 'local currency';
    is $order->{advert_details}{id}, $advert->{id}, 'advert id';
    ok $order->{price} == $price && $order->{price_display} == $price, 'price';
    ok $order->{rate} == $advert->{rate} && $order->{rate_display} == $advert->{rate_display}, 'rate';
    is $order->{status}, 'pending', 'status';
    is $order->{advert_details}{type}, $advert->{type}, 'type';
    is $order->{type}, 'buy', 'type';
    is $order->{payment_info}, $advert->{payment_info}, 'payment_info copied from ad';
    is $order->{contact_info}, $advert->{contact_info}, 'contact_info copied from ad';

    $resp = $t->await::p2p_order_list({
        p2p_order_list => 1,
        offer_id       => ''
    });

    is $resp->{error}->{code}, 'InputValidationFailed', 'offer_id validation error';

    $resp = $t->await::p2p_order_list({p2p_order_list => 1});
    test_schema('p2p_order_list', $resp);
    my $listed_order = $resp->{p2p_order_list}{list}[0];
    $resp = $t->await::p2p_order_info({
            p2p_order_info => 1,
            id             => $order->{id}});
    test_schema('p2p_order_info', $resp);
    my $order_info = $resp->{p2p_order_info};
    cmp_deeply($order_info,   $listed_order, 'Order info matches order list');
    cmp_deeply($listed_order, $order,        'Order list matches order create');
};

subtest 'confirm order' => sub {
    $t->await::authorize({authorize => $token_client});
    $resp = $t->await::p2p_order_confirm({
            p2p_order_confirm => 1,
            id                => $order->{id}});
    test_schema('p2p_order_confirm', $resp);
    is $resp->{p2p_order_confirm}{id}, $order->{id}, 'client confirm: order id';
    is $resp->{p2p_order_confirm}{status}, 'buyer-confirmed', 'client confirm: status';

    $t->await::authorize({authorize => $token_advertiser});
    $resp = $t->await::p2p_order_confirm({
            p2p_order_confirm => 1,
            id                => $order->{id}});
    test_schema('p2p_order_confirm', $resp);
    is $resp->{p2p_order_confirm}{id}, $order->{id}, 'advertiser_confirm: order id';
    is $resp->{p2p_order_confirm}{status}, 'completed', 'advertiser_confirm: status';
};

subtest 'cancel order' => sub {
    $t->await::authorize({authorize => $token_client});
    $order = $t->await::p2p_order_create({
            p2p_order_create => 1,
            advert_id        => $advert->{id},
            amount           => 10
        })->{p2p_order_create};
    $resp = $t->await::p2p_order_cancel({
            p2p_order_cancel => 1,
            id               => $order->{id}});
    test_schema('p2p_order_cancel', $resp);
    is $resp->{p2p_order_cancel}{id}, $order->{id}, 'order id';
    is $resp->{p2p_order_cancel}{status}, 'cancelled', 'status';
};

subtest 'buy advert/sell order' => sub {
    $advert_params{type} = 'buy';
    delete @advert_params{'payment_info', 'contact_info'};    # not allowed for buy advert

    $t->await::authorize({authorize => $token_advertiser});

    $resp = $t->await::p2p_advert_create({
        p2p_advert_create => 1,
        %advert_params
    });
    test_schema('p2p_advert_create', $resp);
    $advert = $resp->{p2p_advert_create};

    my ($payment, $contact) = ('order pay info', 'order contact info');

    $t->await::authorize({authorize => $token_client});
    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $advert->{id},
        amount           => 10,
        payment_info     => $payment,
        contact_info     => $contact
    });
    test_schema('p2p_order_create', $resp);
    $order = $resp->{p2p_order_create};

    is $order->{payment_info}, $payment, 'payment_info';
    is $order->{contact_info}, $contact, 'contact_info';
};

$t->finish_ok;

done_testing();

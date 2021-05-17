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
use BOM::Test::Helper::P2P;
use BOM::User::Client;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::User::Script::P2PDailyMaintenance;
use Guard;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

# We need to restore previous values when tests is done
my %init_config_values = (
    'payments.p2p.enabled'                  => $app_config->payments->p2p->enabled,
    'system.suspend.p2p'                    => $app_config->system->suspend->p2p,
    'payments.p2p.available'                => $app_config->payments->p2p->available,
    'payments.p2p.available_for_countries'  => $app_config->payments->p2p->available_for_countries,
    'payments.p2p.available_for_currencies' => $app_config->payments->p2p->available_for_countries,
    'payments.p2p.limits.maximum_order'     => $app_config->payments->p2p->limits->maximum_order,
    'payments.p2p.archive_ads_days'         => $app_config->payments->p2p->archive_ads_days,
);

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

$app_config->set({'payments.p2p.enabled'                  => 1});
$app_config->set({'system.suspend.p2p'                    => 0});
$app_config->set({'payments.p2p.available'                => 1});
$app_config->set({'payments.p2p.available_for_countries'  => []});
$app_config->set({'payments.p2p.available_for_currencies' => ['usd']});
$app_config->set({'payments.p2p.limits.maximum_order'     => 10});
$app_config->set({'payments.p2p.archive_ads_days'         => 10});

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
        address_line_1         => 'bournani',
        address_city           => 'phraxos',
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
    ok $advertiser->{is_listed},    "advertiser's adverts are listed";
    is $advertiser->{chat_user_id}, 'dummy', 'chat user id';    # from mocked sendbird
    is $advertiser->{chat_token},   'dummy', 'chat token';
    ok $advertiser->{cancels_remaining} > 0, 'cancellations remaining';

    $resp = $t->await::p2p_advertiser_info({p2p_advertiser_info => 1});
    test_schema('p2p_advertiser_info', $resp);

    cmp_deeply($resp->{p2p_advertiser_info}, superhashof($advertiser), 'advertiser info is correct');

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

    $resp = $t->await::p2p_advertiser_update({
            p2p_advertiser_update => 1,
            contact_info          => '',
        })->{error};
    is $resp->{code}, 'AdvertiserNotApproved', 'Not approved advertiser cannot update the information';

    $client_advertiser->p2p_advertiser_update(is_approved => 1);
    delete $client_advertiser->{_p2p_advertiser_cached};

    $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update      => 1,
        is_listed                  => 0,
        contact_info               => '',
        default_advert_description => '',
        payment_info               => '',
    });
    test_schema('p2p_advertiser_update', $resp);
    $advertiser = $resp->{p2p_advertiser_update};
    ok !$advertiser->{is_listed}, "is_listed updated";
    is $advertiser->{contact_info},               '', 'contact_info can be empty';
    is $advertiser->{default_advert_description}, '', 'default_advert_description can be empty';
    is $advertiser->{payment_info},               '', 'payment_info can be empty';

    my ($desc, $payment, $contact) = ('ad descr', 'adv pay info', 'adv contact info');

    $advertiser = $t->await::p2p_advertiser_update({
            p2p_advertiser_update      => 1,
            is_listed                  => 1,
            contact_info               => $contact,
            default_advert_description => $desc,
            payment_info               => $payment,
        })->{p2p_advertiser_update};
    ok $advertiser->{is_listed},                  "is_listed updated";
    is $advertiser->{payment_info},               $payment, 'advertiser payment_info updated';
    is $advertiser->{default_advert_description}, $desc,    'advertiser default_advert_description updated';
    is $advertiser->{contact_info},               $contact, 'advertiser contact_info updated';

    $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update => 1,
        is_listed             => 1,
    });
    test_schema('p2p_advertiser_update', $resp);
    $advertiser = $resp->{p2p_advertiser_update};
    ok $advertiser->{is_listed}, "enable is_listed";

    subtest 'Empty request (response will have extra fields)' => sub {
        $resp = $t->await::p2p_advertiser_update({
            p2p_advertiser_update => 1,
        });
        test_schema('p2p_advertiser_update', $resp);
    };

    subtest 'Client use p2p_advertiser_info' => sub {
        $t->await::authorize({authorize => $token_client});
        $resp = $t->await::p2p_advertiser_info({
                p2p_advertiser_info => 1,
                id                  => $advertiser->{id}});
        test_schema('p2p_advertiser_info', $resp);
    };
};

subtest 'blocked_until' => sub {
    my $block_time = Date::Utility->new->plus_time_interval('1d');
    $client_advertiser->db->dbic->dbh->do('UPDATE p2p.p2p_advertiser SET blocked_until = ? WHERE id = ?',
        undef, $block_time->datetime, $advertiser->{id});

    $t->await::authorize({authorize => $token_advertiser});
    $resp = $t->await::p2p_advertiser_info({p2p_advertiser_info => 1});
    is $resp->{p2p_advertiser_info}{blocked_until}, $block_time->epoch, 'blocked_until returned in advertiser_info';

    $t->await::authorize({authorize => $token_client});
    $resp = $t->await::p2p_advertiser_info({
            p2p_advertiser_info => 1,
            id                  => $advertiser->{id}});
    is $resp->{p2p_advertiser_info}{blocked_until}, undef, 'blocked_until is hidden from others';

    $client_advertiser->db->dbic->dbh->do('UPDATE p2p.p2p_advertiser SET blocked_until = NULL WHERE id = ?', undef, $advertiser->{id});
};

subtest 'chat token' => sub {
    my $token_admin = BOM::Platform::Token::API->new->create_token($client_advertiser->loginid, 'test token', ['admin']);
    $t->await::authorize({authorize => $token_admin});

    my $serivce_token = $t->await::service_token({
            service_token => 1,
            service       => 'sendbird',
        })->{service_token};

    is $serivce_token->{sendbird}{token},       'dummy', 'got token';    # from mocked sendbird
    ok $serivce_token->{sendbird}{expiry_time}, 'got expiry time';
    ok $serivce_token->{sendbird}{app_id},      'got app id';

    $t->await::authorize({authorize => $token_advertiser});
    $resp = $t->await::p2p_advertiser_info({p2p_advertiser_info => 1});
    is $resp->{p2p_advertiser_info}{chat_token}, $serivce_token->{sendbird}{token}, 'token returned by advertiser info';
};

subtest 'create advert (sell)' => sub {
    $t->await::authorize({authorize => $token_advertiser});

    $client_advertiser->p2p_advertiser_update(is_approved => 1);
    delete $client_advertiser->{_p2p_advertiser_cached};

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

    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert->{days_until_archive} = 10;    # not returned for new ad

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
            qw( amount amount_display max_order_amount max_order_amount_display min_order_amount min_order_amount_display remaining_amount remaining_amount_display payment_info contact_info days_until_archive payment_method_ids)
        };
        cmp_deeply($resp->{p2p_advert_info}, \%expected, 'Advert info sensitive fields hidden');
    };

};

subtest 'create order (buy)' => sub {
    my $amount = 10;
    my $price  = $advert->{price} * $amount;
    $resp = $t->await::p2p_advertiser_create({
        p2p_advertiser_create => 1,
        name                  => 'Testclient',
    });
    $client_client->p2p_advertiser_update(is_approved => 1);
    delete $client_client->{_p2p_advertiser_cached};

    my $client_adv_info = $resp->{p2p_advertiser_create};

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $advert->{id},
        amount           => $amount
    });
    test_schema('p2p_order_create', $resp);
    $order = $resp->{p2p_order_create};
    is $order->{account_currency}, $client_advertiser->account->currency_code, 'account currency';
    is $order->{advertiser_details}{id}, $advertiser->{id}, 'advertiser id';
    is $order->{advertiser_details}{name}, $advertiser_params{name}, 'advertiser name';
    ok $order->{amount} == $amount && $order->{amount_display} == $amount, 'amount';
    ok $order->{expiry_time}, 'expiry time';
    is $order->{local_currency}, $advert_params{local_currency}, 'local currency';
    is $order->{advert_details}{id}, $advert->{id}, 'advert id';
    ok $order->{price} == $price && $order->{price_display} == $price, 'price';
    ok $order->{rate} == $advert->{rate} && $order->{rate_display} == $advert->{rate_display}, 'rate';
    is $order->{status}, 'pending', 'status';
    is $order->{advert_details}{type}, $advert->{type}, 'type';
    is $order->{type},         'buy', 'type';
    is $order->{payment_info}, $advert->{payment_info}, 'payment_info copied from ad';
    is $order->{contact_info}, $advert->{contact_info}, 'contact_info copied from ad';
    is $order->{client_details}{id}, $client_adv_info->{id}, 'client id';
    is $order->{client_details}{name}, 'Testclient', 'client name';

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

    # not returned from order list
    delete $order->{payment_method_details};
    delete $order_info->{payment_method_details};

    cmp_deeply($order_info,   $listed_order, 'Order info matches order list');
    cmp_deeply($listed_order, $order,        'Order list matches order create');
};

subtest 'create chat' => sub {
    $t->await::authorize({authorize => $token_client});

    # client needs to be an advertiser to chat about order
    $resp = $t->await::p2p_advertiser_create({
        p2p_advertiser_create => 1,
        name                  => rand(999),
    });

    my $chat = $t->await::p2p_chat_create({
            p2p_chat_create => 1,
            order_id        => $order->{id}})->{p2p_chat_create};

    is $chat->{channel_url}, 'dummy', 'chat channel url';    # from mocked sendbird
    is $chat->{order_id}, $order->{id}, 'order id';
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

subtest 'dispute a order' => sub {
    BOM::Test::Helper::P2P::set_order_disputable($client_client, $order->{id});
    $t->await::authorize({authorize => $token_client});
    $resp = $t->await::p2p_order_dispute({
            p2p_order_dispute => 1,
            dispute_reason    => 'buyer_not_paid',
            id                => $order->{id}});
    test_schema('p2p_order_dispute', $resp);

    is $resp->{p2p_order_dispute}{id}, $order->{id}, 'order id';
    is $resp->{p2p_order_dispute}{dispute_details}{dispute_reason}, 'buyer_not_paid', 'Dispute reason properly set';
    is $resp->{p2p_order_dispute}{dispute_details}{disputer_loginid}, $client_client->loginid, 'Client is the disputer';
};

subtest 'p2p_advert_update' => sub {

    $t->await::authorize({authorize => $token_advertiser});

    my $advert = $t->await::p2p_advert_create({
            p2p_advert_create => 1,
            %advert_params
        })->{p2p_advert_create};

    $resp = $t->await::p2p_advert_update({
        p2p_advert_update => 1,
        id                => $advert->{id},
    });
    test_schema('p2p_advert_update', $resp, 'empty update');

    $resp = $t->await::p2p_advert_update({
        p2p_advert_update => 1,
        id                => $advert->{id},
        is_active         => 0,
    });
    test_schema('p2p_advert_update', $resp, 'actual update');
};

subtest 'show real names' => sub {
    BOM::Test::Helper::P2P::bypass_sendbird();

    my $advertiser_names = {
        first_name => 'john',
        last_name  => 'smith'
    };
    my $client_names = {
        first_name => 'mary',
        last_name  => 'jane'
    };

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
        balance        => 100,
        client_details => {%$advertiser_names});
    my $token_advertiser = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token', ['payments']);

    $t->await::authorize({authorize => $token_advertiser});
    my $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update => 1,
        show_name             => 1,
    });
    ok $resp->{p2p_advertiser_update}{show_name}, 'advertiser update enable show_name';
    cmp_deeply($resp->{p2p_advertiser_update}, superhashof($advertiser_names), 'advertiser update names returned');

    $resp = $t->await::p2p_advertiser_update({
        p2p_advertiser_update => 1,
    });
    cmp_deeply($resp->{p2p_advertiser_update}, superhashof($advertiser_names), 'empty advertiser update names returned');

    my $ad = $t->await::p2p_advert_create({
            p2p_advert_create => 1,
            type              => 'sell',
            amount            => 100,
            rate              => 1,
            min_order_amount  => 1,
            max_order_amount  => 10,
            payment_method    => 'bank_transfer',
            contact_info      => 'x',
            payment_info      => 'x',
        })->{p2p_advert_create};
    cmp_deeply($ad->{advertiser_details}, superhashof($advertiser_names), 'create ad names returned');

    $resp = $t->await::p2p_advert_update({
        p2p_advert_update => 1,
        id                => $ad->{id},
    });
    cmp_deeply($resp->{p2p_advert_update}{advertiser_details}, superhashof($advertiser_names), 'update ad names returned');

    my $client       = BOM::Test::Helper::P2P::create_advertiser(client_details => {%$client_names});
    my $token_client = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token', ['payments']);

    $t->await::authorize({authorize => $token_client});

    $t->await::p2p_advertiser_update({
        p2p_advertiser_update => 1,
        show_name             => 1,
    });

    $resp = $t->await::p2p_advertiser_info({
        p2p_advertiser_info => 1,
        id                  => $advertiser->p2p_advertiser_info->{id},
    });
    cmp_deeply($resp->{p2p_advertiser_info}, superhashof($advertiser_names), 'advertiser info other client real names returned');

    my $order = $t->await::p2p_order_create({
            p2p_order_create => 1,
            advert_id        => $ad->{id},
            amount           => 10,
        })->{p2p_order_create};
    cmp_deeply($order->{advertiser_details}, superhashof($advertiser_names), 'create order advertiser names returned');
    cmp_deeply($order->{client_details},     superhashof($client_names),     'create order client names returned');

    $resp = $t->await::p2p_order_info({
        p2p_order_info => 1,
        id             => $order->{id},
    });
    cmp_deeply($resp->{p2p_order_info}{advertiser_details}, superhashof($advertiser_names), 'order info advertiser names returned');
    cmp_deeply($resp->{p2p_order_info}{client_details},     superhashof($client_names),     'order info client names returned');

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});

    $resp = $t->await::p2p_order_dispute({
            p2p_order_dispute => 1,
            dispute_reason    => 'seller_not_released',
            id                => $order->{id}});
    cmp_deeply($resp->{p2p_order_dispute}{advertiser_details}, superhashof($advertiser_names), 'order dispute advertiser names returned');
    cmp_deeply($resp->{p2p_order_dispute}{client_details},     superhashof($client_names),     'order dispute client names returned');
};

subtest 'ad list name search' => sub {
    $t->await::authorize({authorize => $token_advertiser});

    $client_advertiser->p2p_advertiser_update(name => 'aaa');
    delete $client_advertiser->{_p2p_advertiser_cached};

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list => 1,
        sort_by         => 'completion',
        advertiser_name => 'a'
    });

    ok $resp->{p2p_advert_list}{list}->@*, 'got results';

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list => 1,
        sort_by         => 'completion',
        advertiser_name => 'b'
    });

    ok !$resp->{p2p_advert_list}{list}->@*, 'got no results';
};

$t->finish_ok;

done_testing();

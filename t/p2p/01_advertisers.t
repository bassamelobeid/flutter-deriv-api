use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Warn;
use Log::Any::Test;
use Test::Exception;
use Test::MockTime        qw(set_fixed_time restore_time);
use Format::Util::Numbers qw(formatnumber);
use BOM::User::Client;
use BOM::Config::Redis;
use P2P;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use JSON::MaybeUTF8                            qw(:v1);

BOM::Test::Helper::P2P::bypass_sendbird();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $email = 'p2p_adverts_test@binary.com';

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});

my $user = BOM::User->create(
    email    => $email,
    password => 'test'
);

$user->add_client($test_client_cr);

my $advertiser_name = 'Ad_man';

subtest 'advertiser Registration' => sub {
    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    @emitted_events = ();
    my $p2p_client = P2P->new(client => $client);
    cmp_deeply(exception { $p2p_client->p2p_advertiser_create() }, {error_code => 'AdvertiserNameRequired'}, 'Error when advertiser name is blank');

    my $advertiser;
    lives_ok { $advertiser = $p2p_client->p2p_advertiser_create(name => $advertiser_name) } 'create advertiser ok';

    cmp_deeply(
        \@emitted_events,
        [[
                'p2p_advertiser_created',
                {
                    client_loginid => $client->loginid,
                    %$advertiser
                }]
        ],
        'p2p_advertiser_created event emitted'
    );

    my $advertiser_info = $p2p_client->p2p_advertiser_info;
    ok !$advertiser_info->{is_approved}, "advertiser not approved";
    ok $advertiser_info->{is_listed},    "advertiser adverts are listed";
    cmp_ok $advertiser_info->{name}, 'eq', $advertiser_name, "advertiser name";

    is $client->status->allow_document_upload->{reason}, 'P2P_ADVERTISER_CREATED', 'Can upload auth docs';
};

subtest 'advertiser in POA mandetory countries' => sub {

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    my $p2p_client = P2P->new(client => $client);
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->enabled(1);

    cmp_deeply(
        exception { $p2p_client->p2p_advertiser_create(name => 'advertiser POA') },
        {error_code => 'AuthenticationRequired'},
        'POI and POA required if POA enabled globally'
    );

    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->enabled(0);
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->countries_includes([$client->residence]);
    cmp_deeply(
        exception { $p2p_client->p2p_advertiser_create(name => 'advertiser POA') },
        {error_code => 'AuthenticationRequired'},
        'POI and POA required if POA disabled globally but country is mandetory'
    );

    ok !$client->status->age_verification, "client has not basic verification";
    ok !$client->fully_authenticated,      "client has not full authenticated";

    $client->status->set('age_verification', 'system', 'testing');
    ok $client->status->age_verification, "client has basic verification";
    cmp_deeply(
        exception { $p2p_client->p2p_advertiser_create(name => 'advertiser POA') },
        {error_code => 'AuthenticationRequired'},
        'POI and POA required both not only POI if user is in POA mandetory country'
    );

    $client->status->clear_age_verification;
    $client->set_authentication_and_status('IDV_PHOTO', 'Reej');

    ok !$client->status->age_verification,               "client has not basic verification";
    ok !$client->fully_authenticated({ignore_idv => 1}), "client has not full authenticated with IDV for P2P";

    cmp_deeply(
        exception { $p2p_client->p2p_advertiser_create(name => 'advertiser POA') },
        {error_code => 'AuthenticationRequired'},
        'POI and POA required both not only POA if user is in POA mandetory country'
    );

    $client->status->set('age_verification', 'system', 'testing');
    $client->set_authentication('ID_ONLINE', {status => 'pass'});

    ok $p2p_client->p2p_advertiser_create(name => 'advertiser POA'), 'create advertiser who has POA and POI verified is ok';

    my $client_new     = BOM::Test::Helper::Client::create_client();
    my $p2p_client_new = P2P->new(client => $client_new);
    $client_new->account('USD');

    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->enabled(1);
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->countries_excludes([$client_new->residence]);
    ok $p2p_client_new->p2p_advertiser_create(name => 'advertiser POA 2'), 'create advertiser in country which is excluded is ok';

    ## Set Config as default for rest of the test
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->enabled(0);
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->countries_includes([]);
    BOM::Config::Runtime->instance->app_config->payments->p2p->poa->countries_excludes([]);
};

subtest 'advertiser basic and full verification' => sub {

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    my $p2p_client = P2P->new(client => $client);
    my $advertiser = $p2p_client->p2p_advertiser_create(name => 'advertiser 1');

    my $advertiser_info = $p2p_client->p2p_advertiser_info;
    ok 1, "empty test";

    ok !$advertiser_info->{basic_verification}, "advertiser has not basic verification";
    ok !$advertiser_info->{full_verification},  "advertiser has not full verification";

    $client->status->set('age_verification', 'system', 'testing');
    $client->set_authentication('ID_ONLINE', {status => 'pass'});

    $advertiser_info = $p2p_client->p2p_advertiser_info;

    ok $advertiser_info->{basic_verification}, "advertiser has basic verification";
    ok $advertiser_info->{full_verification},  "advertiser has full verification";
};

subtest 'advertiser already age verified' => sub {

    my $client     = BOM::Test::Helper::Client::create_client();
    my $p2p_client = P2P->new(client => $client);
    $client->account('USD');
    $client->status->set('age_verification', 'system', 'testing');
    ok $p2p_client->p2p_advertiser_create(name => 'age_verified already')->{is_approved};
    ok $p2p_client->p2p_advertiser_info->{is_approved}, 'advertiser is approved';
    ok !$p2p_client->status->allow_document_upload,     'allow_document_upload status not present';
};

subtest 'Duplicate advertiser Registration' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_create(name => $advertiser_name)
        },
        {error_code => 'AlreadyRegistered'},
        "duplicate advertiser request not allowed"
    );
};

subtest 'Advertiser name already taken' => sub {
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    my $client     = BOM::Test::Helper::Client::create_client();

    $client->account('USD');

    cmp_deeply(
        exception { P2P->new(client => $client)->p2p_advertiser_create(name => 'ad_MAN') },
        {error_code => 'AdvertiserNameTaken'},
        "Can't create an advertiser with a name that's already taken"
    );
};

subtest 'Updating advertiser fields' => sub {
    my $advertiser_name = 'test advertiser ' . int(rand(9999));
    my $advertiser      = BOM::Test::Helper::P2P::create_advertiser(name => $advertiser_name);

    my $advertiser_info = $advertiser->p2p_advertiser_info;

    ok $advertiser_info->{is_approved}, 'advertiser is approved';
    is $advertiser_info->{name}, $advertiser_name, 'advertiser name';
    ok $advertiser_info->{is_listed}, 'advertiser is listed';

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(name => ' ');
        },
        {error_code => 'AdvertiserNameRequired'},
        'Error when advertiser name is blank'
    );

    @emitted_events = ();
    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Changing name';
    cmp_deeply(
        \@emitted_events,
        [['p2p_advertiser_updated', {client_loginid => $advertiser->loginid}], ['p2p_adverts_updated', {advertiser_id => $advertiser_info->{id}}],],
        'p2p_advertiser_updated and p2p_adverts_updated events emitted'
    );

    ok !($advertiser->p2p_advertiser_update(is_listed => 0)->{is_listed}), 'Switch flag is_listed to false';

    ok !($advertiser->p2p_advertiser_update(is_approved => 0)->{is_approved}), 'Disable approval';
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(is_listed => 1);
        },
        {error_code => 'AdvertiserNotApproved'},
        'Error when advertiser is not approved'
    );

    ok $advertiser->p2p_advertiser_update(is_approved => 1)->{is_approved}, 'Enabling approval';
    delete $advertiser->{_p2p_advertiser_cached};

    ok $advertiser->p2p_advertiser_update(is_listed => 1)->{is_listed}, 'Switch flag is_listed to true';
    delete $advertiser->{_p2p_advertiser_cached};

    ok !$advertiser->p2p_advertiser_update(is_approved => 0)->{is_listed}, 'Unapproving switches is_listed to false';
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(
                is_listed   => 1,
                is_approved => 0
            );
        },
        {error_code => 'AdvertiserCannotListAds'},
        'Cannot enable is_listed if advertiser is not approved'
    );
};

subtest 'show real name' => sub {
    my $names = {
        first_name => 'john',
        last_name  => 'smith'
    };

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(client_details => {%$names});

    my $details = $advertiser->p2p_advertiser_info;
    is $details->{show_name},  0,     'show_name defaults to 0';
    is $details->{first_name}, undef, 'no first name yet';
    is $details->{last_name},  undef, 'no last name yet';

    cmp_deeply($advertiser->p2p_advertiser_update(show_name => 1), superhashof({%$names, show_name => 1}), 'names returned from advertiser update');
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_deeply($advertiser->p2p_advertiser_info, superhashof({%$names, show_name => 1}), 'names returned from advertiser info');

    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary',
            last_name  => 'jane'
        });
    my $res = $advertiser2->p2p_advertiser_info(id => $details->{id});
    cmp_deeply($res, superhashof($names), 'other client sees names');

    $advertiser->p2p_advertiser_update(show_name => 0);
    delete $advertiser->{_p2p_advertiser_cached};

    $res = $advertiser2->p2p_advertiser_info(id => $details->{id});
    is $res->{first_name}, undef, 'first name hidden from other client';
    is $res->{last_name},  undef, 'last name hidden from other client';

    $res = $advertiser->p2p_advertiser_info;
    is $details->{first_name}, undef, 'correct response for advertiser';
    is $details->{last_name},  undef, 'correct response for advertiser';

};

subtest 'online status' => sub {
    my $redis = BOM::Config::Redis->redis_p2p_write;
    set_fixed_time(1000);

    my $client = BOM::Test::Helper::P2P::create_advertiser();
    $redis->zadd('P2P::USERS_ONLINE', 910, ($client->loginid . "::" . $client->residence));

    cmp_deeply(
        $client->p2p_advertiser_info,
        superhashof({
                is_online        => 1,
                last_online_time => 910,
            }
        ),
        'online at 90s'
    );

    $redis->zadd('P2P::USERS_ONLINE', 909, ($client->loginid . "::" . $client->residence));

    cmp_deeply(
        $client->p2p_advertiser_info,
        superhashof({
                is_online        => 0,
                last_online_time => 909,
            }
        ),
        'offline at 91s'
    );

    restore_time();
};

subtest 'p2p_advertiser_info subscription' => sub {
    my $advertiser1 = BOM::Test::Helper::P2P::create_advertiser;
    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser;

    my $id2   = $advertiser1->_p2p_advertisers(loginid => $advertiser2->loginid)->[0]{id};
    my $info1 = $advertiser1->p2p_advertiser_info;
    my $info2 = $advertiser1->p2p_advertiser_info(id => $id2);

    ok !exists $info1->{client_loginid}, 'loginid not in reponse for self when not subscribe';
    ok !exists $info2->{client_loginid}, 'loginid not in reponse for other when not subscribe';

    cmp_deeply(
        $advertiser1->p2p_advertiser_info(subscribe => 1),
        {%$info1, client_loginid => $advertiser1->loginid},
        'loginid is added to repsonse when subscribe to self'
    );

    cmp_deeply(
        $advertiser1->p2p_advertiser_info(
            id        => $id2,
            subscribe => 1
        ),
        {%$info2, client_loginid => $advertiser2->loginid},
        'loginid is added to repsonse when subscribe to other'
    );
};

subtest 'advertiser band upgrade information' => sub {
    my $advertiser1 = BOM::Test::Helper::P2P::create_advertiser();
    my $info1       = $advertiser1->p2p_advertiser_info;
    ok !exists $info1->{upgradable_daily_limits}, 'advertiser not eligible for band upgrade';

    my $redis       = BOM::Config::Redis->redis_p2p_write;
    my $json_string = "{\"target_max_daily_buy\":\"10000\",\"target_max_daily_sell\":\"10000\"";

    $redis->hset('P2P::ADVERTISER_BAND_UPGRADE_PENDING', $info1->{id}, $json_string);

    ok !exists $advertiser1->p2p_advertiser_info->{upgradable_daily_limits},
        'advertiser next available band information not returned due to invalid JSON data';

    my $data = +{
        target_max_daily_buy  => 10000,
        target_max_daily_sell => 10000,
        target_trade_band     => 'high',
        target_block_trade    => 1,
    };
    $redis->hset('P2P::ADVERTISER_BAND_UPGRADE_PENDING', $info1->{id}, encode_json_utf8($data));

    cmp_deeply(
        $advertiser1->p2p_advertiser_info,
        superhashof({
                upgradable_daily_limits => {
                    max_daily_sell => '10000.00',
                    max_daily_buy  => '10000.00',
                    block_trade    => 1,
                }}
        ),
        'advertiser next available band information returned'
    );

    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser();
    my $info2       = $advertiser2->p2p_advertiser_info(id => $info1->{id});
    ok !exists $info2->{upgradable_daily_limits}, 'advertiser 1 band information not returned to advertiser 2';

};

subtest 'advertiser band update' => sub {
    no warnings;
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
    my $info       = $advertiser->p2p_advertiser_info;

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(upgrade_limits => 1);
        },
        {error_code => 'AdvertiserNotEligibleForLimitUpgrade'},
        'Error when advertiser not eligible for band upgrade'
    );

    delete $advertiser->{_p2p_advertiser_cached};
    my $redis       = BOM::Config::Redis->redis_p2p_write;
    my $json_string = "{\"target_max_daily_buy\":\"10000\",\"target_max_daily_sell\":\"10000\"}}";
    $redis->hset('P2P::ADVERTISER_BAND_UPGRADE_PENDING', $info->{id}, $json_string);

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(upgrade_limits => 1);
        },
        {error_code => 'P2PLimitUpgradeFailed'},
        'Error when invalid JSON data stored'
    );

    # prepare trade band data for medium and high
    BOM::Test::Helper::P2P::populate_trade_band_db();

    @emitted_events = ();
    my $data = +{
        target_max_daily_buy  => 10000,
        target_max_daily_sell => 10000,
        target_trade_band     => "high",
        email_alert_required  => 1,
        account_currency      => $advertiser->currency,
        target_block_trade    => 0,
    };

    $redis->hset('P2P::ADVERTISER_BAND_UPGRADE_PENDING', $info->{id}, encode_json_utf8($data));
    my $update = $advertiser->p2p_advertiser_update(upgrade_limits => 1);
    delete $advertiser->{_p2p_advertiser_cached};
    ok !exists $update->{upgradable_daily_limits}, 'limit upgrade was successful';
    is $redis->hget('P2P::ADVERTISER_BAND_UPGRADE_PENDING', $info->{id}), undef, 'redis field deleted successfully';

    cmp_deeply([$update->@{qw(daily_buy_limit daily_sell_limit)}], ["10000.00", "10000.00"], 'new buy and sell limit values reflected correctly');

    cmp_deeply(
        \@emitted_events,
        [
            ['p2p_advertiser_updated', {client_loginid => $advertiser->loginid}],
            ['p2p_adverts_updated',    {advertiser_id  => $update->{id}}],
            [
                'p2p_limit_changed',
                {
                    loginid           => $advertiser->loginid,
                    advertiser_id     => $update->{id},
                    new_sell_limit    => formatnumber('amount', $advertiser->currency, "10000"),
                    new_buy_limit     => formatnumber('amount', $advertiser->currency, "10000"),
                    account_currency  => $advertiser->currency,
                    change            => 1,
                    automatic_approve => 0,
                    block_trade       => 0,
                }
            ],
        ],
        'p2p_advertiser_updated, p2p_adverts_updated and p2p_limit_changed events emitted'
    );

    my $upgrade_done = decode_json_utf8($redis->hget('P2P::ADVERTISER_BAND_UPGRADE_COMPLETED', $info->{id}));

    cmp_deeply($upgrade_done, superhashof($data), 'upgrade success data populated correctly');
};

done_testing;

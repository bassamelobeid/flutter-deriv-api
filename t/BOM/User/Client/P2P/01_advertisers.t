use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use Test::MockTime qw(set_fixed_time restore_time);

use BOM::User::Client;
use BOM::Config::Redis;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

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

    cmp_deeply(exception { $client->p2p_advertiser_create() }, {error_code => 'AdvertiserNameRequired'}, 'Error when advertiser name is blank');

    my $advertiser;
    lives_ok { $advertiser = $client->p2p_advertiser_create(name => $advertiser_name) } 'create advertiser ok';

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

    my $advertiser_info = $client->p2p_advertiser_info;
    ok !$advertiser_info->{is_approved}, "advertiser not approved";
    ok $advertiser_info->{is_listed}, "advertiser adverts are listed";
    cmp_ok $advertiser_info->{name}, 'eq', $advertiser_name, "advertiser name";

    is $client->status->allow_document_upload->{reason}, 'P2P_ADVERTISER_CREATED', 'Can upload auth docs';
};

subtest 'advertiser already age verified' => sub {

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    $client->status->set('age_verification', 'system', 'testing');
    ok $client->p2p_advertiser_create(name => 'age_verified already')->{is_approved};
    ok $client->p2p_advertiser_info->{is_approved}, 'advertiser is approved';
    ok !$client->status->allow_document_upload, 'allow_document_upload status not present';
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
        exception { $client->p2p_advertiser_create(name => 'ad_MAN') },
        {error_code => 'AdvertiserNameTaken'},
        "Can't create an advertiser with a name that's already taken"
    );
};

subtest 'Updating advertiser fields' => sub {
    my $advertiser_name = 'test advertiser ' . int(rand(9999));
    my $advertiser      = BOM::Test::Helper::P2P::create_advertiser(name => $advertiser_name);

    my $advertiser_info = $advertiser->p2p_advertiser_info;

    ok $advertiser_info->{is_approved}, 'advertiser is approved';
    is $advertiser_info->{name},        $advertiser_name, 'advertiser name';
    ok $advertiser_info->{is_listed},   'advertiser is listed';

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
    $redis->zadd('P2P::USERS_ONLINE', 910, $client->loginid);

    cmp_deeply(
        $client->p2p_advertiser_info,
        superhashof({
                is_online        => 1,
                last_online_time => 910,
            }
        ),
        'online at 90s'
    );

    $redis->zadd('P2P::USERS_ONLINE', 909, $client->loginid);

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

done_testing;

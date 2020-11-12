use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Exception;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();

my %last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        %last_event = (
            type => $type,
            data => $data
        );
    });

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

    cmp_deeply(exception { $client->p2p_advertiser_create() }, {error_code => 'AdvertiserNameRequired'}, 'Error when advertiser name is blank');

    my $advertiser;
    lives_ok { $advertiser = $client->p2p_advertiser_create(name => $advertiser_name) } 'create advertiser ok';

    cmp_deeply(
        \%last_event,
        {
            type => 'p2p_advertiser_created',
            data => {
                client_loginid => $client->loginid,
                %$advertiser
            }
        },
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
        \%last_event,
        {
            type => 'p2p_advertiser_updated',
            data => {client_loginid => $advertiser->loginid}
        },
        'p2p_advertiser_updated event emitted'
    );

    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(name => ' ');
        },
        {error_code => 'AdvertiserNameRequired'},
        'Error when advertiser name is blank'
    );

    is $advertiser->p2p_advertiser_update(name => 'test')->{name}, 'test', 'Changing name';

    ok !($advertiser->p2p_advertiser_update(is_listed => 0)->{is_listed}), 'Switch flag is_listed to false';

    ok !($advertiser->p2p_advertiser_update(is_approved => 0)->{is_approved}), 'Disable approval';
    cmp_deeply(
        exception {
            $advertiser->p2p_advertiser_update(is_listed => 1);
        },
        {error_code => 'AdvertiserNotApproved'},
        'Error when advertiser is not approved'
    );

    ok $advertiser->p2p_advertiser_update(is_approved => 1)->{is_approved}, 'Enabling approval';
    ok $advertiser->p2p_advertiser_update(is_listed   => 1)->{is_listed},   'Switch flag is_listed to true';
    ok !$advertiser->p2p_advertiser_update(is_approved => 0)->{is_listed}, 'Unapproving switches is_listed to false';

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
    cmp_deeply($advertiser->p2p_advertiser_info,                   superhashof({%$names, show_name => 1}), 'names returned from advertiser info');

    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary',
            last_name  => 'jane'
        });
    my $res = $advertiser2->p2p_advertiser_info(id => $details->{id});
    cmp_deeply($res, superhashof($names), 'other client sees names');

    $advertiser->p2p_advertiser_update(show_name => 0);
    $res = $advertiser2->p2p_advertiser_info(id => $details->{id});
    is $res->{first_name}, undef, 'first name hidden from other client';
    is $res->{last_name},  undef, 'last name hidden from other client';

    $res = $advertiser->p2p_advertiser_info;
    is $details->{first_name}, undef, 'correct response for advertiser';
    is $details->{last_name},  undef, 'correct response for advertiser';

};

done_testing;

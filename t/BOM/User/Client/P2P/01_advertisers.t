use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::Exception;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Test::Helper::P2P::bypass_sendbird();

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
    my $client = BOM::Test::Helper::P2P::create_client();

    lives_ok(sub { $client->p2p_advertiser_approve }, 'no error trying to approve non advertiser');

    cmp_deeply(exception { $client->p2p_advertiser_create() }, {error_code => 'AdvertiserNameRequired'}, 'Error when advertiser name is blank');

    ok $client->p2p_advertiser_create(name => $advertiser_name), "create advertiser";
    my $advertiser_info = $client->p2p_advertiser_info;
    ok !$advertiser_info->{is_approved}, "advertiser not approved";
    ok $advertiser_info->{is_listed}, "advertiser adverts are listed";
    cmp_ok $advertiser_info->{name}, 'eq', $advertiser_name, "advertiser name";

    is $client->status->allow_document_upload->{reason}, 'P2P advertiser created', 'Can upload auth docs';
    $client->p2p_advertiser_approve;
    ok $client->p2p_advertiser_info->{is_approved}, 'advertiser is approved';
    ok !$client->status->allow_document_upload, 'allow_document_upload status removed after approval';
};

subtest 'advertiser already authenticated' => sub {

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock('fully_authenticated', sub { 1 });

    my $client = BOM::Test::Helper::P2P::create_client();
    ok $client->p2p_advertiser_create(name => 'approved already')->{is_approved}, "create advertiser";
    my $advertiser_info = $client->p2p_advertiser_info;
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
    my $client     = BOM::Test::Helper::P2P::create_client();

    cmp_deeply(
        exception { $client->p2p_advertiser_create(name => 'ad_MAN') },
        {error_code => 'AdvertiserNameTaken'},
        "Can't create an advertiser with a name that's already taken"
    );
};

subtest 'Updating advertiser fields' => sub {
    my $advertiser_name = 'test advertiser ' . int(rand(9999));
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(name => $advertiser_name);

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

done_testing;

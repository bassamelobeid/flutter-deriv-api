use strict;
use warnings;

use Test::Deep;
use Test::More;
use Time::Moment;
use Future::AsyncAwait;
use Log::Any::Test;
use BOM::Event::Actions::MT5;
use Test::MockModule;
use BOM::User;
use BOM::User::Client;
use BOM::Event::Actions::MT5TechnicalAccounts;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $mocked_mt5_async = Test::MockModule->new('BOM::MT5::User::Async');
my $mocked_module    = Test::MockModule->new('BOM::Event::Actions::MT5TechnicalAccounts');
my $test_client      = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$user->add_client($test_client);
$test_client->binary_user_id($user->id);

subtest 'create_mt5_ib_technical_accounts' => sub {
    my $params = {
        mt5_account_id => 'MTR120000568',
        provider       => 'dynamicworks',
        partner_id     => 'CU1234567',
        binary_user_id => $test_client->binary_user_id,
    };
    $mocked_module->mock(
        '_get_main_mt5_account',
        sub {
            return Future->done({
                    currency => 'usd',
                    data     => {
                        balance       => '0.00',
                        phonePassword => '',
                        email         => $test_client->email,
                        address       => 'ADDR 1',
                        leverage      => 500,
                        country       => 'Indonesia',
                        phone         => '+62417541477',
                        rights        => 485,
                        comment       => '',
                        state         => '',
                        color         => 4278190080,
                        company       => '',
                        zipCode       => '',
                        agent         => 0,
                        city          => 'Cyber',
                        group         => 'real\\p03_ts01\\synthetic\\svg_std_usd\\02',
                        name          => 'QA script testhSQ'
                    }});
        });

    $mocked_mt5_async->mock(
        'create_user',
        sub {
            return Future->done({
                login => 'MTR1111111',
            });
        });
    my $result = BOM::Event::Actions::MT5TechnicalAccounts::create_mt5_ib_technical_accounts($params);

    ok($result, 'create_mt5_ib_technical_accounts executed successfully');

    $mocked_module->unmock('_get_main_mt5_account');
    $mocked_mt5_async->unmock('create_user');
};

subtest '_get_main_mt5_account success scenario' => sub {
    $mocked_mt5_async->mock(
        'get_user',
        sub {
            return Future->done({
                balance       => '0.00',
                phonePassword => '',
                email         => $test_client->email,
                address       => 'ADDR 1',
                leverage      => 500,
                country       => 'Indonesia',
                phone         => '+62417541477',
                rights        => 485,
                comment       => '',
                state         => '',
                color         => 4278190080,
                company       => '',
                zipCode       => '',
                agent         => 0,
                city          => 'Cyber',
                group         => 'real\\p03_ts01\\synthetic\\svg_std_usd\\02',
                name          => 'QA script testhSQ'
            });
        });

    $mocked_mt5_async->mock(
        'get_group',
        sub {
            return Future->done({
                currency => 'usd',
            });
        });

    my $user = {comment => ' '};

    $mocked_mt5_async->mock(
        'update_user',
        sub {
            my ($user) = @_;
            is($user->{comment}, 'IB', 'User comment updated to IB');
            return Future->done(1);
        });

    my $result_future = BOM::Event::Actions::MT5TechnicalAccounts::_get_main_mt5_account('MTR120000568');
    my $result        = $result_future->get;

    is($result->{currency},        'usd',               'Currency is correctly set to USD');
    is($result->{data}->{balance}, '0.00',              'Balance is correctly retrieved');
    is($result->{data}->{name},    'QA script testhSQ', 'Name is correctly retrieved');

    $mocked_mt5_async->unmock('get_user');
    $mocked_mt5_async->unmock('get_group');
    $mocked_mt5_async->unmock('update_user');

};

subtest '_add_ib_comment does not update comment when already IB' => sub {
    my $user = {comment => 'IB'};

    my $result_future = BOM::Event::Actions::MT5TechnicalAccounts::_add_ib_comment('MTR120000568', $user);
    my $result        = $result_future->get;

    is($result, 0, '_add_ib_comment did not update the comment as it was already IB');

};

done_testing();

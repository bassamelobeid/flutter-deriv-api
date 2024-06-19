use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client);
use BOM::RPC::v3::MT5::Account;
use Clone 'clone';

my $mock_user    = Test::MockModule->new('BOM::User');
my $mock_client  = Test::MockModule->new('BOM::User::Client');
my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emissions    = [];

$emitter_mock->mock(
    'emit',
    sub {
        push $emissions->@*, {@_};
    });

my $sample_bvi_mt5_active = {
    MTR1000018 => {
        account_type => "real",
        attributes   => {
            account_type    => "real",
            currency        => "USD",
            group           => "real\\p01_ts01\\financial\\bvi_std_usd",
            landing_company => "svg",
            leverage        => 300,
            market_type     => "financial",
        },
        creation_stamp => "2018-02-14 07:13:52.94334",
        currency       => "USD",
        loginid        => "MTR1000018",
        platform       => "mt5",
        status         => undef,
    },
};

my %bom_user_mock = (
    loginid_details => sub {
        $mock_user->mock('loginid_details', shift // sub { $sample_bvi_mt5_active });
    });

subtest '_kyc_cashier_permission_check' => sub {
    my $user = BOM::User->create(
        email    => 'mt5_cashier_resync_test@gmail.com',
        password => 'Dummy123',
    );
    my $test_client = create_client('CR');
    $test_client->email($user->email);
    $test_client->binary_user_id($user->id);
    $user->add_client($test_client);

    $bom_user_mock{loginid_details}->();

    subtest 'test if rule fails is triggered, to trigger a resync call' => sub {
        $emissions = [];
        my $result =
            BOM::RPC::v3::MT5::Account::_kyc_cashier_permission_check({client => $test_client, mt5_loginid => 'MTR1000018', operation => 'deposit'});
        cmp_deeply $result, {error_code => "MT5KYCDepositLocked"}, 'call sucessfully failed with MT5KYCDepositLocked';
        cmp_deeply $emissions, [{sync_mt5_accounts_status => {client_loginid => "CR10000"}}], 'Expected sync_mt5_accounts_status emission';

    };

    subtest 'test if existing account have status but rule did not fail, to trigger a resync call' => sub {
        $emissions = [];
        $mock_client->mock(get_poi_status_jurisdiction => sub { return 'verified' });
        $mock_client->mock(get_poa_status              => sub { return 'verified' });
        my $bvi_mt5_poa_failed = clone($sample_bvi_mt5_active);
        $bvi_mt5_poa_failed->{MTR1000018}{status} = 'poa_failed';
        $bom_user_mock{loginid_details}->(sub { $bvi_mt5_poa_failed });

        my $result =
            BOM::RPC::v3::MT5::Account::_kyc_cashier_permission_check({client => $test_client, mt5_loginid => 'MTR1000018', operation => 'deposit'});
        cmp_deeply $result, {ok => 1}, 'call sucessfully when account flagged with wrong status';
        cmp_deeply $emissions,
            [{sync_mt5_accounts_status => {client_loginid => "CR10000"}}],
            'Expected sync_mt5_accounts_status emission to correct the mismatch';
    };
};

done_testing();

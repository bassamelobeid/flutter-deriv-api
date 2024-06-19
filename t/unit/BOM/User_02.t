use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use Test::Deep;
use BOM::User;

# We're gonna try to use a pure object, no DB involved.
# Mock all the stuff you need.

my $user_mock = Test::MockModule->new('BOM::User');
$user_mock->redefine(new => sub { return bless({}, 'BOM::User') });

subtest 'get_default_client' => sub {
    my $fake_data = {
        'CR1000' => {
            'loginid'        => 'CR1000',
            'wallet_loginid' => 'CRW1000',
            'broker_code'    => 'CR',
            'platform'       => 'dtrade',
            'account_type'   => 'real',
            'is_virtual'     => 0,
            'is_wallet'      => 0,
            'is_external'    => 0,
            'status'         => undef,
            'client'         => {
                'get_self_exclusion_until_date' => 0,
                'status'                        => {
                    'disabled'          => undef,
                    'duplicate_account' => undef,
                }}
        },
        'CR1001' => {
            'loginid'        => 'CR1001',
            'wallet_loginid' => 'CRW1000',
            'broker_code'    => 'CR',
            'platform'       => 'dtrade',
            'account_type'   => 'real',
            'is_virtual'     => 0,
            'is_wallet'      => 0,
            'is_external'    => 0,
            'status'         => undef,
            'client'         => {
                'get_self_exclusion_until_date' => 1,
                'status'                        => {
                    'disabled'          => undef,
                    'duplicate_account' => undef,
                }}
        },
        'CRW1000' => {
            'loginid'        => 'CRW1000',
            'wallet_loginid' => undef,
            'broker_code'    => 'CRW',
            'platform'       => 'dwallet',
            'account_type'   => '',
            'is_virtual'     => 0,
            'is_wallet'      => 1,
            'is_external'    => 0,
            'status'         => undef,
            'client'         => {
                'get_self_exclusion_until_date' => 0,
                'status'                        => {
                    'disabled'          => undef,
                    'duplicate_account' => undef,
                }}
        },
        'VRTC1000' => {
            'loginid'        => 'VRTC1000',
            'wallet_loginid' => undef,
            'broker_code'    => 'VRTC',
            'platform'       => 'dtrade',
            'account_type'   => '',
            'is_virtual'     => 1,
            'is_wallet'      => 0,
            'is_external'    => 0,
            'status'         => undef,
            'client'         => {
                'get_self_exclusion_until_date' => 0,
                'status'                        => {
                    'disabled'          => undef,
                    'duplicate_account' => undef,
                }}
        },
        'MTD1000' => {
            'loginid'        => 'MTD1000',
            'wallet_loginid' => undef,
            'broker_code'    => 'MTD',
            'platform'       => 'mt5',
            'account_type'   => '',
            'is_virtual'     => 0,
            'is_wallet'      => 0,
            'is_external'    => 1,
            'status'         => undef,
            'client'         => {
                'get_self_exclusion_until_date' => 0,
                'status'                        => {
                    'disabled'          => undef,
                    'duplicate_account' => undef,
                }}}};

    my $mock_module = Test::MockModule->new('BOM::User::Client');

    $mock_module->mock(
        get_client_instance => sub {
            my ($class, $login_id) = @_;
            my $data = $fake_data->{$login_id};

            return unless $data;

            my $client = bless {blob => $data}, 'BOM::User::Client';

            $mock_module->mock('loginid',                       sub { my ($self) = @_; $self->{blob}->{loginid} });
            $mock_module->mock('get_self_exclusion_until_date', sub { my ($self) = @_; $self->{blob}{client}->{get_self_exclusion_until_date} });

            my $status_obj = bless {}, 'BOM::User::Client::Status';    # Mock the status object
            $status_obj->{disabled}          = $data->{client}->{status}->{disabled};
            $status_obj->{duplicate_account} = $data->{client}->{status}->{duplicate_account};

            $mock_module->mock('status', sub { return $status_obj });

            # Mock status object methods
            Test::MockModule->new('BOM::User::Client::Status')->mock('disabled',          sub { $status_obj->{disabled} });
            Test::MockModule->new('BOM::User::Client::Status')->mock('duplicate_account', sub { $status_obj->{duplicate_account} });

            return $client;
        });

    # *** NOTES TO BE REMEMBERED HERE ***
    #
    # 1. Remember to 'new' the user object for each test to clear the cache
    # 2  Fake the loginid_detils on your new object
    # 3. Every time you mutate the fake_data, remember to put it back to the default state
    #
    # Follow these guidelines and you will not get in a mess

    my $client;
    my $user;

    $user = BOM::User->new;
    $user->{loginid_details} = {};
    is($user->get_default_client(), undef, 'No loginid_details, no client');

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    ok($client = $user->get_default_client(), 'Got a default client');
    is $client->loginid, 'CR1000', 'CR1000 is the default client';

    $user                                                = BOM::User->new;
    $user->{loginid_details}                             = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client()->loginid, 'CRW1000', 'CRW1000 is the default client, when CR1000 is disabled');
    $fake_data->{CR1000}->{client}->{status}->{disabled} = undef;

    $user                                                         = BOM::User->new;
    $user->{loginid_details}                                      = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = {'status_code' => 'duplicate_account'};
    is($user->get_default_client()->loginid, 'CRW1000', 'CR1000 is duplicate, cache is cleared so CRW1000 should be the default client');
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled}  = {'status_code' => 'disabled'};
    $fake_data->{CRW1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client()->loginid, 'VRTC1000', 'Check order, if CRW1000 & CR1000 are disabled, VTRC should be the default client');
    $fake_data->{CR1000}->{client}->{status}->{disabled}  = undef;
    $fake_data->{CRW1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = {'status_code' => 'disabled'};
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = {'status_code' => 'disabled'};
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client()->loginid,
        'CR1001', 'Check order, if CRW1000, CR1000 & VRTC1000 are disabled, CR1001 should be the default client, self excluded');
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = undef;
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = undef;
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = {'status_code' => 'disabled'};
    $fake_data->{CR1001}->{client}->{status}->{disabled}   = {'status_code' => 'disabled'};
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = {'status_code' => 'disabled'};
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client(), undef, 'All usable accounts disabled, no default client available');
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = undef;
    $fake_data->{CR1001}->{client}->{status}->{disabled}   = undef;
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = undef;
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = {'status_code' => 'disabled'};
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = {'status_code' => 'disabled'};
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client(include_disabled => 1)->loginid,
        'CR1000', 'All usable accounts disabled, but include_disabled is enabled, so CR1000 is the default client');
    $fake_data->{CR1000}->{client}->{status}->{disabled}   = undef;
    $fake_data->{CRW1000}->{client}->{status}->{disabled}  = undef;
    $fake_data->{VRTC1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = {'status_code' => 'duplicate_account'};
    $fake_data->{CR1001}->{client}->{status}->{duplicate_account} = {'status_code' => 'duplicate_account'};
    $fake_data->{CRW1000}->{client}->{status}->{disabled}         = {'status_code' => 'disabled'};
    $fake_data->{VRTC1000}->{client}->{status}->{disabled}        = {'status_code' => 'disabled'};
    is($user->get_default_client(include_disabled => 1)->loginid, 'CRW1000', 'CRW1000 is the default if disabled because CR1000 is a duplicate');
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = undef;
    $fake_data->{CRW1000}->{client}->{status}->{disabled}         = undef;
    $fake_data->{VRTC1000}->{client}->{status}->{disabled}        = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    $fake_data->{CR1000}->{client}->{status}->{disabled}            = {'status_code' => 'disabled'};
    $fake_data->{CRW1000}->{client}->{status}->{duplicate_account}  = {'status_code' => 'duplicate_account'};
    $fake_data->{VRTC1000}->{client}->{status}->{duplicate_account} = {'status_code' => 'duplicate_account'};
    is($user->get_default_client(include_duplicated => 1)->loginid, 'CRW1000', 'CRW1000 is the default if duplicate because CR1000 is disabled');
    $fake_data->{CR1000}->{client}->{status}->{disabled}            = undef;
    $fake_data->{CRW1000}->{client}->{status}->{duplicate_account}  = undef;
    $fake_data->{VRTC1000}->{client}->{status}->{duplicate_account} = undef;

    # Caching tests, change the underlying data and check if the client is still the same, in real
    # life this can never happen, but we're testing the caching mechanism here, we'll keep the same
    # user object that has an initialised cache
    # Setup the data such that we have different clients for the different cache keys then change
    # the underlying data so nothing should be returned but we should get expected cache values

    # We can't make multiple mocks so we will create a single cache entry, make sure its in the
    # cache and then make temp data so nothing should be returned and check we still get our cache
    # entry back.
    # Cache keys to test:
    #   _default_client
    #   _default_client_include_disabled
    #   _default_client_include_duplicated
    #   _default_client_include_disabled_include_duplicated

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    is($user->get_default_client()->loginid,        'CR1000', 'Cache setup test, default client no flags');
    is($user->{_default_client}->loginid,           'CR1000', 'Cache key _default_client expected value present');
    is($user->{_default_client_include_disabled},   undef,    'Cache key _default_client_include_disabled should be empty');
    is($user->{_default_client_include_duplicated}, undef,    'Cache key _default_client_include_duplicated should be empty');
    is($user->{_default_client_include_disabled_include_duplicated},
        undef, 'Cache key _default_client_include_disabled_include_duplicated should be empty');
    # Change underlying data so we should get next VRTC but should still get CR1000 because cache
    $fake_data->{CR1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client()->loginid, 'CR1000', 'Cache key _default_client returns cache value after underlying data change');
    $fake_data->{CR1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    is($user->get_default_client(include_disabled => 1)->loginid, 'CR1000', 'Cache setup test, default client include_disabled flags');
    is($user->{_default_client},                                  undef,    'Cache key _default_client should be empty');
    is($user->{_default_client_include_disabled} && $user->{_default_client_include_disabled}->loginid,
        'CR1000', 'Cache key _default_client_include_disabled expected value present');
    is($user->{_default_client_include_duplicated}, undef, 'Cache key _default_client_include_duplicated should be empty');
    is($user->{_default_client_include_disabled_include_duplicated},
        undef, 'Cache key _default_client_include_disabled_include_duplicated should be empty');
    # Change underlying data so we should get next VRTC but should still get CR1000 because cache
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = {'status_code' => 'duplicate_account'};
    is($user->get_default_client(include_disabled => 1)->loginid,
        'CR1000', 'Cache key _default_client returns cache value after underlying data change');
    $fake_data->{CR1000}->{client}->{status}->{duplicate_account} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    is($user->get_default_client(include_duplicated => 1)->loginid, 'CR1000', 'Cache setup test, default client include_duplicated flags');
    is($user->{_default_client},                                    undef,    'Cache key _default_client should be empty');
    is($user->{_default_client_include_disabled},                   undef,    'Cache key _default_client_include_disabled should be empty');
    is($user->{_default_client_include_duplicated} && $user->{_default_client_include_duplicated}->loginid,
        'CR1000', 'Cache key _default_client_include_duplicated expected value present');
    is($user->{_default_client_include_disabled_include_duplicated},
        undef, 'Cache key _default_client_include_disabled_include_duplicated should be empty');
    # Change underlying data so we should get next VRTC but should still get CR1000 because cache
    $fake_data->{CR1000}->{client}->{status}->{disabled} = {'status_code' => 'disabled'};
    is($user->get_default_client(include_duplicated => 1)->loginid,
        'CR1000', 'Cache key _default_client returns cache value after underlying data change');
    $fake_data->{CR1000}->{client}->{status}->{disabled} = undef;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;
    is(
        $user->get_default_client(
            include_disabled   => 1,
            include_duplicated => 1
        )->loginid,
        'CR1000',
        'Cache setup test, default client include_duplicated flags'
    );
    is($user->{_default_client},                    undef, 'Cache key _default_client should be empty');
    is($user->{_default_client_include_disabled},   undef, 'Cache key _default_client_include_disabled should be empty');
    is($user->{_default_client_include_duplicated}, undef, 'Cache key _default_client_include_disabled_include_duplicated should be empty');
    is($user->{_default_client_include_disabled_include_duplicated} && $user->{_default_client_include_disabled_include_duplicated}->loginid,
        'CR1000', 'Cache key _default_client_include_disabled_include_duplicated expected value present');
    # Change underlying data so we should get next VRTC but should still get CR1000 because cache
    $fake_data->{CR1000}->{is_external}  = 1;
    $fake_data->{CRW1000}->{is_external} = 1;
    is(
        $user->get_default_client(
            include_disabled   => 1,
            include_duplicated => 1
        )->loginid,
        'CR1000',
        'Cache key _default_client returns cache value after underlying data change'
    );
    $fake_data->{CR1000}->{is_external}  = 0;
    $fake_data->{CRW1000}->{is_external} = 0;

};

done_testing();

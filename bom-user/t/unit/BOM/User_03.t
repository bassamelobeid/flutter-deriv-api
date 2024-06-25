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

my $fake_data = {
    'CR1000' => {
        'description'    => 'NORMAL_CLIENT',
        'loginid'        => 'CR1000',
        'wallet_loginid' => 'CRW1000',
        'broker_code'    => 'CR',
        'platform'       => 'dtrade',
        'account_type'   => 'real',
        'is_virtual'     => 0,
        'is_wallet'      => 0,
        'is_external'    => 0,
        'is_enabled'     => 1,
        'is_excluded'    => 0,
        'is_duplicated'  => 0
    },
    'CR1001' => {
        'description'    => 'DISABLED_CLIENT',
        'loginid'        => 'CR1001',
        'wallet_loginid' => 'CRW1000',
        'broker_code'    => 'CR',
        'platform'       => 'dtrade',
        'account_type'   => 'real',
        'is_virtual'     => 0,
        'is_wallet'      => 0,
        'is_external'    => 0,
        'is_enabled'     => 0,
        'is_excluded'    => 0,
        'is_duplicated'  => 0
    },
    'CR1002' => {
        'description'    => 'EXCLUDED_CLIENT',
        'loginid'        => 'CR1002',
        'wallet_loginid' => 'CRW1000',
        'broker_code'    => 'CR',
        'platform'       => 'dtrade',
        'account_type'   => 'real',
        'is_virtual'     => 0,
        'is_wallet'      => 0,
        'is_external'    => 0,
        'is_enabled'     => 1,
        'is_excluded'    => 1,
        'is_duplicated'  => 0
    },
    'CR1003' => {
        'description'    => 'DUPLICATED_CLIENT',
        'loginid'        => 'CR1003',
        'wallet_loginid' => 'CRW1000',
        'broker_code'    => 'CR',
        'platform'       => 'dtrade',
        'account_type'   => 'real',
        'is_virtual'     => 0,
        'is_wallet'      => 0,
        'is_external'    => 0,
        'is_enabled'     => 1,
        'is_excluded'    => 0,
        'is_duplicated'  => 1
    },
    'CRW1000' => {
        'description'    => 'NORMAL_WALLET',
        'loginid'        => 'CRW1000',
        'wallet_loginid' => undef,
        'broker_code'    => 'CRW',
        'platform'       => 'dwallet',
        'account_type'   => '',
        'is_virtual'     => 0,
        'is_wallet'      => 1,
        'is_external'    => 0,
        'is_enabled'     => 1,
        'is_excluded'    => 0,
        'is_duplicated'  => 0
    },
    'VRTC1000' => {
        'description'    => 'VIRTUAL_CLIENT',
        'loginid'        => 'VRTC1000',
        'wallet_loginid' => undef,
        'broker_code'    => 'VRTC',
        'platform'       => 'dtrade',
        'account_type'   => '',
        'is_virtual'     => 1,
        'is_wallet'      => 0,
        'is_external'    => 0,
        'is_enabled'     => 1,
        'is_excluded'    => 0,
        'is_duplicated'  => 0
    },
    'MTD1000' => {
        'description'    => 'EXTERNAL_CLIENT',
        'loginid'        => 'MTD1000',
        'wallet_loginid' => undef,
        'broker_code'    => 'MTD',
        'platform'       => 'mt5',
        'account_type'   => '',
        'is_virtual'     => 0,
        'is_wallet'      => 0,
        'is_external'    => 1,
        'is_enabled'     => 1,
        'is_excluded'    => 0,
        'is_duplicated'  => 0
    }};

subtest 'get_clients_in_sorted_order' => sub {
    $user_mock->mock(
        accounts_by_category => sub {
            my ($class, $loginid_list, %args) = @_;

            my $account_list = {
                enabled       => [],
                virtual       => [],
                self_excluded => [],
                disabled      => [],
                duplicated    => []};
            foreach my $loginid (@$loginid_list) {

                next if (!$args{include_duplicated} && $fake_data->{$loginid}->{is_duplicated});

                if (!$fake_data->{$loginid}->{is_enabled}) {
                    push @{$account_list->{disabled}}, $fake_data->{$loginid}->{description};
                    next;
                }
                if ($fake_data->{$loginid}->{is_excluded}) {
                    push @{$account_list->{self_excluded}}, $fake_data->{$loginid}->{description};
                    next;
                }
                if ($fake_data->{$loginid}->{is_virtual}) {
                    push @{$account_list->{virtual}}, $fake_data->{$loginid}->{description};
                    next;
                }
                if ($fake_data->{$loginid}->{is_duplicated}) {
                    push @{$account_list->{duplicated}}, $fake_data->{$loginid}->{description};
                    next;
                }
                push @{$account_list->{enabled}}, $fake_data->{$loginid}->{description};
            }
            return $account_list;
        });

    my $user;
    my $clients;

    $user = BOM::User->new;
    $user->{loginid_details} = $fake_data;

    $clients = $user->get_clients_in_sorted_order();
    is_deeply(
        $clients,
        ['NORMAL_CLIENT', 'NORMAL_WALLET', 'VIRTUAL_CLIENT', 'EXCLUDED_CLIENT', 'DISABLED_CLIENT'],
        'Default list, no external, no duplicated'
    );

    $clients = $user->get_clients_in_sorted_order(include_virtual => 1);
    is_deeply(
        $clients,
        ['NORMAL_CLIENT', 'NORMAL_WALLET', 'VIRTUAL_CLIENT', 'EXCLUDED_CLIENT', 'DISABLED_CLIENT'],
        'Include virtual, same as default'
    );

    $clients = $user->get_clients_in_sorted_order(include_virtual => 0);
    is_deeply($clients, ['NORMAL_CLIENT', 'NORMAL_WALLET', 'EXCLUDED_CLIENT', 'DISABLED_CLIENT'], 'Exclude virtual');

    $clients = $user->get_clients_in_sorted_order(include_duplicated => 1);
    is_deeply(
        $clients,
        ['NORMAL_CLIENT', 'NORMAL_WALLET', 'VIRTUAL_CLIENT', 'EXCLUDED_CLIENT', 'DISABLED_CLIENT', "DUPLICATED_CLIENT"],
        'Include duplicated'
    );
};

subtest 'landing companies' => sub {
    my $user = BOM::User->new;

    $user->{loginid_details} = $fake_data;

    my $lcs = $user->landing_companies();

    $lcs = +{map { $_ => $lcs->{$_}->short } keys $lcs->%*};

    is_deeply(
        $lcs,
        +{
            CR1000   => 'svg',
            CR1001   => 'svg',
            CR1002   => 'svg',
            CR1003   => 'svg',
            CRW1000  => 'svg',
            VRTC1000 => 'virtual',
        },
        'Expected landing companies'
    );
};

done_testing();

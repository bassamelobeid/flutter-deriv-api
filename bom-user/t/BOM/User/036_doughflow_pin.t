use strict;
use warnings;
use Test::More;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Customer;
use BOM::User;
use BOM::User::Client;

subtest 'wallets' => sub {
    my $customer = BOM::Test::Customer->create(
        clients => [{
                name         => 'CR',
                broker_code  => 'CR',
                account_type => 'standard',
            },
            {
                name         => 'CRW',
                broker_code  => 'CRW',
                account_type => 'doughflow',
            },
            {
                name        => 'VRW',
                broker_code => 'VRW'
            },
        ]);
    my $df_wallet = $customer->get_client_object('CRW');
    my $standard  = $customer->get_client_object('CR');
    my $virtual   = $customer->get_client_object('VRW');

    is $df_wallet->doughflow_pin, $df_wallet->loginid, 'new wallet doughflow_pin is loginid';
    my $instance = BOM::User::Client->get_client_instance_by_doughflow_pin($df_wallet->doughflow_pin);
    is $instance->loginid, $df_wallet->loginid, 'get_client_instance_by_doughflow_pin using loginid';

    $df_wallet->set_doughflow_pin($standard->loginid);

    is $df_wallet->doughflow_pin, $standard->loginid, 'wallet doughflow_pin is mapped loginid';
    $instance = BOM::User::Client->get_client_instance_by_doughflow_pin($df_wallet->doughflow_pin);
    is $instance->loginid, $df_wallet->loginid, 'get_client_instance_by_doughflow_pin using loginid';

    like exception { $standard->doughflow_pin }, qr/doughflow_pin is not applicable to this account type/, 'doughflow_pin error for standard account';
    like exception { $standard->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
        'set_doughflow_pin error for standard account';

    like exception { $virtual->doughflow_pin }, qr/doughflow_pin is not applicable to this account type/, 'doughflow_pin error for virtual wallet';
    like exception { $virtual->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
        'set_doughflow_pin error for virtual wallet';

    for my $type (qw(crypto p2p paymentagent paymentagent_client)) {
        my $wallet = $customer->create_client(
            name         => $type,
            broker_code  => 'CRW',
            account_type => $type,
        );
        like exception { $wallet->doughflow_pin }, qr/doughflow_pin is not applicable to this account type/, "doughflow_pin error for $type wallet";
        like exception { $wallet->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
            "set_doughflow_pin error for $type wallet";
    }
};

subtest 'legacy account' => sub {
    my $customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
        ]);
    my $legacy  = $customer->get_client_object('CR');
    my $virtual = $customer->get_client_object('VRTC');

    is $legacy->doughflow_pin, $legacy->loginid, 'legacy doughflow_pin is loginid';
    like exception { $legacy->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
        'set_doughflow_pin error for legacy CR account';

    like exception { $virtual->doughflow_pin },     qr/doughflow_pin is not applicable to this account type/,     'doughflow_pin error for VRTC';
    like exception { $virtual->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/, 'set_doughflow_pin error for VRTC';

};

done_testing();

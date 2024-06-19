use strict;
use warnings;
use Test::More;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::User;
use BOM::User::Client;

subtest 'wallets' => sub {

    my $user = BOM::User->create(
        email    => 'wallet@deriv.com',
        password => 'x',
    );

    my $df_wallet =
        BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow', binary_user_id => $user->id});
    $user->add_client($df_wallet);

    my $standard =
        BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', account_type => 'standard', binary_user_id => $user->id});
    $user->add_client($standard);

    my $virtual =
        BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRW', account_type => 'virtual', binary_user_id => $user->id});
    $user->add_client($virtual);

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
        my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => $type});
        $user->add_client($wallet);
        like exception { $wallet->doughflow_pin }, qr/doughflow_pin is not applicable to this account type/, "doughflow_pin error for $type wallet";
        like exception { $wallet->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
            "set_doughflow_pin error for $type wallet";
    }
};

subtest 'legacy account' => sub {

    my $user = BOM::User->create(
        email    => 'legacy@deriv.com',
        password => 'x',
    );

    my $virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
    $user->add_client($virtual);

    my $legacy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $user->add_client($legacy);

    is $legacy->doughflow_pin, $legacy->loginid, 'legacy doughflow_pin is loginid';
    like exception { $legacy->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/,
        'set_doughflow_pin error for legacy CR account';

    like exception { $virtual->doughflow_pin },     qr/doughflow_pin is not applicable to this account type/,     'doughflow_pin error for VRTC';
    like exception { $virtual->set_doughflow_pin }, qr/set_doughflow_pin is not applicable to this account type/, 'set_doughflow_pin error for VRTC';

};

done_testing();

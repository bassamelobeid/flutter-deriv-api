use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use Test::Deep;
use Test::Warnings;
use BOM::User;
use List::Util;
use Storable qw(dclone);

my @loginids = ({
        loginid      => 'VRTC001',
        platform     => 'dtrade',
        account_type => 'demo',
    },
    {
        loginid => 'VRTC002',    # this is to test fallback values of platform and account_type
    },
    {
        loginid        => 'VRTC003',
        platform       => 'dtrade',
        account_type   => 'demo',
        wallet_loginid => 'VRW001'
    },
    {
        loginid      => 'VRTJ001',
        platform     => 'dtrade',
        account_type => 'demo',
    },
    {
        loginid => 'VRTJ002',
    },
    {
        loginid      => 'VRTU001',
        platform     => 'dtrade',
        account_type => 'demo',
    },
    {
        loginid => 'VRTU002',
    },
    {
        loginid      => 'CR001',
        platform     => 'dtrade',
        account_type => 'real',
    },
    {
        loginid => 'CR002',
    },
    {
        loginid        => 'CR003',
        platform       => 'dtrade',
        account_type   => 'real',
        wallet_loginid => 'CRW001'
    },
    {
        loginid      => 'MF001',
        platform     => 'dtrade',
        account_type => 'real',
    },
    {
        loginid => 'MF002',
    },
    {
        loginid      => 'JP001',
        platform     => 'dtrade',
        account_type => 'real',
    },
    {
        loginid => 'JP002',
    },
    {
        loginid      => 'AFF001',
        platform     => 'dtrade',
        account_type => 'real',
    },
    {
        loginid => 'AFF002',
    },
    {
        loginid      => 'VRW001',
        platform     => 'dwallet',
        account_type => 'demo',
    },
    {
        loginid => 'VRW002',
    },
    {
        loginid      => 'CRW001',
        platform     => 'dwallet',
        account_type => 'real',
    },
    {
        loginid => 'CRW002',
    },
    {
        loginid      => 'CRA001',
        platform     => 'dwallet',
        account_type => 'real',
    },
    {
        loginid => 'CRA002',
    },
    {
        loginid      => 'MFW001',
        platform     => 'dwallet',
        account_type => 'real',
    },
    {
        loginid => 'MFW002',
    },
    {
        loginid      => 'MTD001',
        platform     => 'mt5',
        account_type => 'demo',
    },
    {
        loginid => 'MTD002',
    },
    {
        loginid      => 'MTD003',
        platform     => 'mt5',
        account_type => 'demo',
        status       => 'poa_outdated',
    },
    {
        loginid      => 'MTD004',
        platform     => 'mt5',
        account_type => 'demo',
        status       => 'disabled',
    },
    {
        loginid        => 'MTD005',
        platform       => 'mt5',
        account_type   => 'demo',
        wallet_loginid => 'VRW001',
    },
    {
        loginid      => 'MT001',
        platform     => 'mt5',
        account_type => 'real',
    },
    {
        loginid => 'MT002',
    },
    {
        loginid      => 'MTR001',
        platform     => 'mt5',
        account_type => 'real',
    },
    {
        loginid => 'MTR002',
    },
    {
        loginid      => 'MTR003',
        platform     => 'mt5',
        account_type => 'real',
        status       => 'verification_pending',
    },
    {
        loginid      => 'MTR004',
        platform     => 'mt5',
        account_type => 'real',
        status       => 'archived',
    },
    {
        loginid        => 'MTR005',
        platform       => 'mt5',
        account_type   => 'real',
        wallet_loginid => 'CRW001',
    },
    {
        loginid      => 'DXD001',
        platform     => 'dxtrade',
        account_type => 'demo',
    },
    {
        loginid => 'DXD002',
    },
    {
        loginid      => 'DXR001',
        platform     => 'dxtrade',
        account_type => 'real',
    },
    {
        loginid => 'DXR002',
    },
    {
        loginid      => 'EZD001',
        platform     => 'derivez',
        account_type => 'demo',
    },
    {
        loginid => 'EZD002',
    },
    {
        loginid      => 'EZR001',
        platform     => 'derivez',
        account_type => 'real',
    },
    {
        loginid => 'EZR002',
    },
    {
        loginid      => 'CTD001',
        platform     => 'ctrader',
        account_type => 'demo',
    },
    {
        loginid => 'CTD002',
    },
    {
        loginid      => 'CTR001',
        platform     => 'ctrader',
        account_type => 'real',
    },
    {
        loginid => 'CTR002',
    },
);

my $dbic_mock = Test::MockObject->new();
$dbic_mock->mock(run => sub { dclone(\@loginids) });
my $user_mock = Test::MockModule->new('BOM::User');
$user_mock->redefine(dbic => $dbic_mock);
$user_mock->redefine(new  => sub { return bless({}, 'BOM::User') });

my $user = BOM::User->new;

cmp_deeply([keys $user->loginid_details->%*], bag(map { $_->{loginid} } @loginids), 'loginid_details() returns all loginids');

cmp_deeply([$user->loginids], bag(map { $_->{loginid} } @loginids), 'loginids() returns all loginids');

ok((List::Util::all { $_->{platform} }, values $user->loginid_details->%*), 'platform have a value for all loginids');
ok((List::Util::all { defined $_->{account_type} }, values $user->loginid_details->%*), 'account_type is defined for all loginids');

cmp_deeply(
    [$user->bom_loginids],
    bag(
        qw(VRTC001 VRTC002 VRTC003 VRTJ001 VRTJ002 VRTU001 VRTU002
            CR001 CR002 CR003 MF001 MF002 JP001 JP002 AFF001 AFF002
            VRW001 VRW002 CRW001 CRW002 CRA001 CRA002 MFW001 MFW002)
    ),
    'bom_loginids'
);

cmp_deeply(
    [$user->bom_real_loginids],
    bag(
        qw(CR001 CR002 CR003 MF001 MF002 JP001 JP002 AFF001 AFF002
            CRW001 CRW002 CRA001 CRA002 MFW001 MFW002)
    ),
    'bom_real_loginids'
);

my @orig        = @loginids;
my @vr_loginids = qw(VRTC001 VRTC002 VRTC003 VRTJ001 VRTJ002 VRTU001 VRTU002);
for my $vr_loginid (@vr_loginids) {
    delete $user->{loginid_details};
    # make sure bom vr login is chosen when it's the only one amongst all other types of accounts
    @loginids = grep {
        my $l = $_->{loginid};
        $l eq $vr_loginid or List::Util::none { $l eq $_ } @vr_loginids
    } @orig;
    is $user->bom_virtual_loginid, $vr_loginid, "bom_virtual_loginid (when $vr_loginid is the only possibilty)";
}

@vr_loginids = qw(VRW001 VRW002);
for my $vr_wallet (@vr_loginids) {
    delete $user->{loginid_details};
    @loginids = grep {
        my $l = $_->{loginid};
        $l eq $vr_wallet or List::Util::none { $l eq $_ } @vr_loginids
    } @orig;
    is $user->bom_virtual_wallet_loginid, $vr_wallet, "bom_virtual_wallet_loginid (when $vr_wallet is the only possibilty)";
}

@loginids = @orig;
delete $user->{loginid_details};

cmp_deeply([$user->get_mt5_loginids], bag(qw(MTD001 MTD002 MTD003 MTD005 MT001 MT002 MTR001 MTR002 MTR003 MTR005)), 'get_mt5_loginids (no args)');

cmp_deeply([$user->get_mt5_loginids(type_of_account => 'demo')], bag(qw(MTD001 MTD002 MTD003 MTD005)), 'get_mt5_loginids (type_of_account = demo)');

cmp_deeply(
    [$user->get_mt5_loginids(type_of_account => 'real')],
    bag(qw( MT001 MT002 MTR001 MTR002 MTR003 MTR005)),
    'get_mt5_loginids (type_of_account = real)'
);

cmp_deeply(
    [$user->get_mt5_loginids(wallet_loginid => undef)],
    bag(qw(MTD001 MTD002 MTD003 MT001 MT002 MTR001 MTR002 MTR003)),
    'get_mt5_loginids (wallet_loginid = undef)'
);

cmp_deeply([$user->get_mt5_loginids(wallet_loginid => 'VRW001')], bag(qw(MTD005)), 'get_mt5_loginids (wallet_loginid = virtual wallet)');

cmp_deeply([$user->get_mt5_loginids(wallet_loginid => 'CRW001')], bag(qw(MTR005)), 'get_mt5_loginids (wallet_loginid = real wallet)');

cmp_deeply(
    [$user->get_mt5_loginids(include_all_status => 1)],
    bag(qw(MTD001 MTD002 MTD003 MTD004 MTD005 MT001 MT002 MTR001 MTR002 MTR003 MTR004 MTR005)),
    'get_mt5_loginids (include_all_status = 1)'
);

cmp_deeply([$user->get_dxtrade_loginids], bag(qw(DXD001 DXD002 DXR001 DXR002)), 'get_dxtrade_loginids (no args)');

cmp_deeply([$user->get_dxtrade_loginids(type_of_account => 'demo')], bag(qw(DXD001 DXD002)), 'get_dxtrade_loginids (type_of_account = demo)');

cmp_deeply([$user->get_dxtrade_loginids(type_of_account => 'real')], bag(qw(DXR001 DXR002)), 'get_dxtrade_loginids (type_of_account = real)');

cmp_deeply([$user->get_derivez_loginids], bag(qw(EZD001 EZD002 EZR001 EZR002)), 'get_derivez_loginids (no args)');

cmp_deeply([$user->get_derivez_loginids(type_of_account => 'demo')], bag(qw(EZD001 EZD002)), 'get_derivez_loginids (type_of_account = demo)');

cmp_deeply([$user->get_derivez_loginids(type_of_account => 'real')], bag(qw(EZR001 EZR002)), 'get_derivez_loginids (type_of_account = real)');

cmp_deeply([$user->get_ctrader_loginids], bag(qw(CTD001 CTD002 CTR001 CTR002)), 'get_ctrader_loginids (no args)');

cmp_deeply([$user->get_ctrader_loginids(type_of_account => 'demo')], bag(qw(CTD001 CTD002)), 'get_ctrader_loginids (type_of_account = demo)');

cmp_deeply([$user->get_ctrader_loginids(type_of_account => 'real')], bag(qw(CTR001 CTR002)), 'get_ctrader_loginids (type_of_account = real)');

done_testing();

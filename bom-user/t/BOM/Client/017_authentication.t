use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init no_auth_method_sync);    # disable auth method sync db trigger for this test
use BOM::Test::Helper::Client;
use BOM::Test::Email;

my %clients;
my ($user, $generator) = BOM::Test::Helper::Client::create_wallet_factory();
$clients{vrw}     = $generator->('VRW', 'virtual', 'USD');
$clients{vrtc}    = $generator->('VRTC', 'standard', 'USD', $clients{vrw}->loginid);
$clients{crw_df}  = $generator->('CRW', 'doughflow', 'USD');
$clients{cr_df}   = $generator->('CR', 'standard', 'USD', $clients{crw_df}->loginid);
$clients{crw_p2p} = $generator->('CRW', 'p2p',       'USD');
$clients{mfw_df}  = $generator->('MFW', 'doughflow', 'USD');
$clients{mf_df}   = $generator->('MF', 'standard', 'USD', $clients{mfw_df}->loginid);

my $mock_client = Test::MockModule->new('BOM::User::Client');
my @mifir_updates;
$mock_client->redefine(update_mifir_id => sub { push @mifir_updates, shift->loginid });

my $mock_virtual     = Test::MockModule->new('LandingCompany::Virtual');
my $mock_svg         = Test::MockModule->new('LandingCompany::SVG');
my $mock_maltainvest = Test::MockModule->new('LandingCompany::MaltaInvest');
my $mock_malta       = Test::MockModule->new('LandingCompany::Malta');

$mock_virtual->redefine(allowed_landing_companies_for_authentication_sync => []);
$mock_svg->redefine(allowed_landing_companies_for_authentication_sync => []);
$mock_maltainvest->redefine(allowed_landing_companies_for_authentication_sync => ['svg']);
$mock_malta->redefine(allowed_landing_companies_for_authentication_sync => ['maltainvest']);

subtest 'add_single_authentication_method' => sub {
    my $cli = $clients{cr_df};

    reset_clients();
    $cli->add_single_authentication_method(
        method => 'ID_DOCUMENT',
        status => 'needs_action',
        staff  => 'staff1'
    );
    my $status = $cli->status->allow_document_upload;
    is $status->{reason},     'MARKED_AS_NEEDS_ACTION', 'reason for allow_document_upload';
    is $status->{staff_name}, 'staff1',                 'staff for allow_document_upload';

    reset_clients();
    $cli->status->set('allow_document_upload', 'staff2', 'reason2');
    $cli->add_single_authentication_method(
        method => 'ID_DOCUMENT',
        status => 'needs_action',
        staff  => 'staff3'
    );
    $status = $cli->status->allow_document_upload;
    is $status->{reason},     'reason2', 'reason for allow_document_upload is preserved';
    is $status->{staff_name}, 'staff2',  'staff for allow_document_upload is preserved';

    reset_clients();
    $cli->add_single_authentication_method(
        method => 'ID_DOCUMENT',
        status => 'pass',
        staff  => 'staff4'
    );
    $status = $cli->status->address_verified;
    is $status->{reason},     'address verified', 'reason for address_verified';
    is $status->{staff_name}, 'staff4',           'staff for address_verified';

    reset_clients();
    $cli->status->set('address_verified', 'staff5', 'reason5');
    $cli->add_single_authentication_method(
        method => 'ID_DOCUMENT',
        status => 'pass',
        staff  => 'staff6'
    );
    $status = $cli->status->address_verified;
    is $status->{reason},     'address verified', 'reason for address_verified is overwritten';
    is $status->{staff_name}, 'staff6',           'staff for address_verified is overwritten';

    my @tests = ({
            client       => 'vrtc',
            method       => 'ID_DOCUMENT',
            status       => 'pass',
            address      => 1,
            mifir_update => 1
        },
        {
            client     => 'vrtc',
            method     => 'ID_DOCUMENT',
            status     => 'needs_action',
            doc_upload => 1
        },
        {
            client  => 'vrtc',
            method  => 'ID_NOTARIZED',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'vrtc',
            method  => 'ID_PO_BOX',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'vrtc',
            method  => 'ID_ONLINE',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'vrtc',
            method  => 'IDV',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'vrtc',
            method  => 'IDV_ADDRESS',
            status  => 'pass',
            address => 1
        },
        {
            client => 'vrtc',
            method => 'IDV_PHOTO',
            status => 'pass'
        },
        {
            client       => 'cr_df',
            method       => 'ID_DOCUMENT',
            status       => 'pass',
            address      => 1,
            mifir_update => 1
        },
        {
            client     => 'cr_df',
            method     => 'ID_DOCUMENT',
            status     => 'needs_action',
            doc_upload => 1
        },
        {
            client  => 'cr_df',
            method  => 'ID_NOTARIZED',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'cr_df',
            method  => 'ID_PO_BOX',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'cr_df',
            method  => 'ID_ONLINE',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'cr_df',
            method  => 'IDV',
            status  => 'pass',
            address => 1
        },
        {
            client  => 'cr_df',
            method  => 'IDV_ADDRESS',
            status  => 'pass',
            address => 1
        },
        {
            client => 'cr_df',
            method => 'IDV_PHOTO',
            status => 'pass'
        },
    );

    for my $test (@tests) {
        reset_clients();
        @mifir_updates = ();

        my ($method, $status) = $test->@{qw(method status)};
        my $cli = $clients{$test->{client}};

        subtest join(' ', $test->{client}, $method, $status) => sub {
            # statuses that should be cleared
            $cli->status->set('address_verified',      'x', 'x') unless $test->{address};
            $cli->status->set('allow_document_upload', 'x', 'x') unless $test->{doc_upload};

            $cli->add_single_authentication_method(
                method => $method,
                status => $status
            );

            ok my $auth = $cli->get_authentication($method), "$method is set";
            is $auth->authentication_method_code, $method, "method is $method";
            is $auth->status,                     $status, "status is $status";
            is $cli->status->address_verified ? 1 : 0, $test->{address} // 0, 'address_verified status: ' . ($test->{address} ? 'yes' : 'no');
            is $cli->status->allow_document_upload ? 1 : 0, $test->{doc_upload} // 0,
                'allow_document_upload status: ' . ($test->{doc_upload} ? 'yes' : 'no');
            if ($test->{mifir_update}) {
                cmp_deeply \@mifir_updates, [$cli->loginid], 'update_mifir_id() was called';
            } else {
                cmp_deeply \@mifir_updates, [], 'update_mifir_id() was not called';
            }
        };
    }
};

my @single_auths;
$mock_client->redefine(
    add_single_authentication_method => sub {
        my ($self, %args) = @_;
        push @single_auths, [$self->loginid, @args{qw(method status)}];
    });

subtest 'set_authentication' => sub {

    reset_clients();
    @single_auths = ();
    $clients{vrw}->set_authentication('ID_DOCUMENT', {status => 'pass'});

    cmp_bag(
        \@single_auths,
        [[$clients{vrw}->loginid, 'ID_DOCUMENT', 'pass'], [$clients{vrtc}->loginid, 'ID_DOCUMENT', 'pass'],],
        'expected siblings set from vrw'
    );

    reset_clients();
    @single_auths = ();
    $clients{cr_df}->set_authentication('ID_DOCUMENT', {status => 'pass'});

    cmp_bag(
        \@single_auths,
        [
            [$clients{cr_df}->loginid,   'ID_DOCUMENT', 'pass'],
            [$clients{crw_df}->loginid,  'ID_DOCUMENT', 'pass'],
            [$clients{crw_p2p}->loginid, 'ID_DOCUMENT', 'pass'],
        ],
        'expected siblings set from cr for syncable method'
    );

    reset_clients();
    @single_auths = ();
    $clients{crw_p2p}->set_authentication('IDV', {status => 'needs_action'});

    cmp_bag(
        \@single_auths,
        [
            [$clients{cr_df}->loginid,   'IDV', 'needs_action'],
            [$clients{crw_df}->loginid,  'IDV', 'needs_action'],
            [$clients{crw_p2p}->loginid, 'IDV', 'needs_action'],
        ],
        'expected siblings set from crw for non syncable method'
    );

    reset_clients();
    @single_auths = ();
    $clients{mfw_df}->set_authentication('ID_ONLINE', {status => 'pass'});

    cmp_bag(
        \@single_auths,
        [[$clients{mf_df}->loginid, 'ID_ONLINE', 'pass'], [$clients{mfw_df}->loginid,, 'ID_ONLINE', 'pass'],],
        'expected siblings set from mfw for non syncable method'
    );

    reset_clients();
    @single_auths = ();
    $clients{mf_df}->set_authentication('ID_NOTARIZED', {status => 'pass'});

    cmp_bag(
        \@single_auths,
        [
            [$clients{mf_df}->loginid,   'ID_NOTARIZED', 'pass'],
            [$clients{mfw_df}->loginid,  'ID_NOTARIZED', 'pass'],
            [$clients{cr_df}->loginid,   'ID_NOTARIZED', 'pass'],
            [$clients{crw_df}->loginid,  'ID_NOTARIZED', 'pass'],
            [$clients{crw_p2p}->loginid, 'ID_NOTARIZED', 'pass'],
        ],
        'expected siblings set from mf for syncable method'
    );

    subtest 'MF compliance email' => sub {
        my $user = BOM::User->create(
            email    => 'mf1@test.com',
            password => 'x',
        );

        my $client_mf  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
        my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
        $user->add_client($client_mf);
        $user->add_client($client_mlt);

        @single_auths = ();
        $client_mlt->set_authentication('ID_PO_BOX', {status => 'pass'});

        cmp_bag(
            \@single_auths,
            [[$client_mf->loginid, 'ID_PO_BOX', 'pass'], [$client_mlt->loginid, 'ID_PO_BOX', 'pass'],],
            'expected siblings set from mlt for syncable method'
        );

        ok mailbox_search(subject => qr/New authenticated MF from MLT/), 'email sent to CS about MF getting authenticated from other LC';
    };
};

subtest 'sync_authentication_from_siblings' => sub {

    reset_clients();
    $clients{vrtc}->add_client_authentication_method({authentication_method_code => 'ID_DOCUMENT', status => 'pass'});
    $clients{vrtc}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'vrtc' } keys %clients;

    cmp_bag(\@single_auths, [[$clients{vrw}->loginid, 'ID_DOCUMENT', 'pass'],], 'syncable method copied from VRW to VRTC');

    reset_clients();
    $clients{vrw}->add_client_authentication_method({authentication_method_code => 'IDV', status => 'needs_action'});
    $clients{vrw}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'vrw' } keys %clients;

    cmp_bag(\@single_auths, [[$clients{vrtc}->loginid, 'IDV', 'needs_action'],], 'non syncable method copied from VRTC from VRW');

    reset_clients();
    $clients{cr_df}->add_client_authentication_method({authentication_method_code => 'ID_NOTARIZED', status => 'needs_action'});
    $clients{cr_df}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'cr_df' } keys %clients;

    cmp_bag(
        \@single_auths,
        [[$clients{crw_df}->loginid, 'ID_NOTARIZED', 'needs_action'], [$clients{crw_p2p}->loginid, 'ID_NOTARIZED', 'needs_action'],],
        'syncable method copied from CR to CRW'
    );

    reset_clients();
    $clients{crw_p2p}->add_client_authentication_method({authentication_method_code => 'IDV_ADDRESS', status => 'pass'});
    $clients{crw_p2p}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'crw_p2p' } keys %clients;

    cmp_bag(
        \@single_auths,
        [[$clients{crw_df}->loginid, 'IDV_ADDRESS', 'pass'], [$clients{cr_df}->loginid, 'IDV_ADDRESS', 'pass'],],
        'non-syncable method copied from CRW to CR and CRW'
    );

    reset_clients();
    $clients{mfw_df}->add_client_authentication_method({authentication_method_code => 'ID_PO_BOX', status => 'needs_action'});
    $clients{mfw_df}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'mfw_df' } keys %clients;

    cmp_bag(
        \@single_auths,
        [
            [$clients{mf_df}->loginid,   'ID_PO_BOX', 'needs_action'],
            [$clients{crw_df}->loginid,  'ID_PO_BOX', 'needs_action'],
            [$clients{cr_df}->loginid,   'ID_PO_BOX', 'needs_action'],
            [$clients{crw_p2p}->loginid, 'ID_PO_BOX', 'needs_action'],
        ],
        'syncable method copied from MFW to MF, CRW and CR'
    );

    reset_clients();
    $clients{mf_df}->add_client_authentication_method({authentication_method_code => 'IDV_PHOTO', status => 'pass'});
    $clients{mf_df}->save;

    @single_auths = ();
    $clients{$_}->sync_authentication_from_siblings() for grep { $_ ne 'mf_df' } keys %clients;

    cmp_bag(\@single_auths, [[$clients{mfw_df}->loginid, 'IDV_PHOTO', 'pass'],], 'non-syncable method copied from MF to MFW');

    subtest 'MF compliance email' => sub {
        my $user = BOM::User->create(
            email    => 'mf2@test.com',
            password => 'x',
        );

        my $client_mf  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
        my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
        $user->add_client($client_mf);
        $user->add_client($client_mlt);

        @single_auths = ();
        $client_mlt->add_client_authentication_method({authentication_method_code => 'ID_DOCUMENT', status => 'pass'});
        $client_mlt->save;
        $client_mf->sync_authentication_from_siblings();

        cmp_bag(\@single_auths, [[$client_mf->loginid, 'ID_DOCUMENT', 'pass'],], 'syncable method copied from MLT to MF');

        ok mailbox_search(subject => qr/New authenticated MF from MLT/), 'email sent to CS about MF getting authenticated from other LC';
    };
};

subtest 'set_authentication_and_status' => sub {

    my $cli = $clients{cr_df};

    my @set_auths;
    $mock_client->redefine(set_authentication => sub { shift; push @set_auths, \@_; });

    for my $type (qw(IDV IDV_ADDRESS IDV_PHOTO ID_NOTARIZED ID_PO_BOX ID_DOCUMENT ID_ONLINE)) {
        @set_auths = ();
        my $staff = rand();
        $cli->set_authentication_and_status($type, $staff);

        cmp_deeply(\@set_auths, [[$type, {status => 'pass'}, $staff]], $type);
    }

    @set_auths = ();
    my $staff = rand();
    $cli->set_authentication_and_status('NEEDS_ACTION', $staff);

    cmp_deeply(\@set_auths, [['ID_DOCUMENT', {status => 'needs_action'}, $staff]], 'NEEDS_ACTION');

    @set_auths = ();
    $cli->set_authentication_and_status('blah', 'x');
    cmp_deeply(\@set_auths, [], 'unknown type');
};

done_testing;

sub reset_clients {
    for my $cli (values %clients) {
        $_->delete for $cli->client_authentication_method->@*;
        $cli->client_authentication_method(undef);
        $cli->status->clear_address_verified;
        $cli->status->clear_allow_document_upload;
        $cli->save;
    }
}

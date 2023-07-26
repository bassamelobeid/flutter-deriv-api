use strict;
use warnings;
use Test::More;
use Test::MockModule;

use BOM::User::Client;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'jurisdiction based POI' => sub {
    # client to play with
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email          => 'jurisdiction+poi@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);

    # mocks

    my $client_mock = Test::MockModule->new(ref($client));

    my $manual_status;
    $client_mock->mock(
        'get_manual_poi_status',
        sub {
            return $manual_status;
        });

    my $onfido_status;
    $client_mock->mock(
        'get_onfido_status',
        sub {
            return $onfido_status;
        });

    my $idv_status;
    $client_mock->mock(
        'get_idv_status',
        sub {
            return $idv_status;
        });

    # test collection

    my $tests = [{
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'none',
            remark => '(all none)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'verified',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by Onfido)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'verified',
            },
            result => 'verified',
            remark => '(verified by Manual)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'none',
            remark => '(IDV does not work for this)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'none',
            remark => '(all none)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'verified',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by Onfido)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'verified',
            },
            result => 'verified',
            remark => '(verified by Manual)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(IDV now works for vanuatu)',
        },
        {
            scenario => {
                landing_company => 'labuan',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'none',
            remark => '(all none)',
        },
        {
            scenario => {
                landing_company => 'labuan',
                onfido          => 'verified',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by Onfido)',
        },
        {
            scenario => {
                landing_company => 'labuan',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'verified',
            },
            result => 'verified',
            remark => '(verified by Manual)',
        },
        {
            scenario => {
                landing_company => 'labuan',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by IDV)',
        },
        {
            scenario => {
                landing_company => 'bvi',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'none',
            remark => '(all none)',
        },
        {
            scenario => {
                landing_company => 'bvi',
                onfido          => 'verified',
                idv             => 'none',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by Onfido)',
        },
        {
            scenario => {
                landing_company => 'bvi',
                onfido          => 'none',
                idv             => 'none',
                manual          => 'verified',
            },
            result => 'verified',
            remark => '(verified by Manual)',
        },
        {
            scenario => {
                landing_company => 'bvi',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified by IDV)',
        },
        {
            scenario => {
                landing_company => 'bvi',
                onfido          => 'pending',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(verified has higher priority than pending)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'pending',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'pending',
            remark => '(IDV does not work, so pending by Onfido)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'suspected',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'suspected',
            remark => '(IDV does not work, so suspected by Onfido)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'rejected',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'rejected',
            remark => '(IDV does not work, so rejected by Onfido)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'expired',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'expired',
            remark => '(IDV does not work, so expired by Onfido)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
                dob_mismatch    => 1,
            },
            result => 'rejected',
            remark => '(rejected by DOB mismatch)',
        },
        {
            scenario => {
                landing_company => 'maltainvest',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
                name_mismatch   => 1,
            },
            result => 'rejected',
            remark => '(rejected by Name mismatch)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'pending',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'suspected',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'rejected',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'expired',
                idv             => 'verified',
                manual          => 'none',
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
                dob_mismatch    => 1,
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {
                landing_company => 'vanuatu',
                onfido          => 'none',
                idv             => 'verified',
                manual          => 'none',
                name_mismatch   => 1,
            },
            result => 'verified',
            remark => '(IDV verified + Vanuatu = verified)',
        },
        {
            scenario => {

            },
            result => 'none',
            remark => '(no LC given)',
        },
        {
            scenario => {landing_company => 'team_rocket'},
            result   => 'none',
            remark   => '(no valid LC given)',
        },
    ];

    # test battleground!

    foreach my $test ($tests->@*) {
        my ($scenario, $result, $remark) = @{$test}{qw/scenario result remark/};
        my ($landing_company, $onfido, $idv, $manual, $dob_mismatch, $name_mismatch) =
            @{$scenario}{qw/landing_company onfido idv manual dob_mismatch name_mismatch/};

        $client->status->set('poi_name_mismatch', 'test', 'test') if $name_mismatch;

        $client->status->set('poi_dob_mismatch', 'test', 'test') if $dob_mismatch;

        $client->status->_build_all;

        $onfido_status = $onfido // 'none';
        $idv_status    = $idv    // 'none';
        $manual_status = $manual // 'none';
        $landing_company //= '';
        $remark          //= '';

        is $client->get_poi_status_jurisdiction({landing_company => $landing_company}), $result,
            "[$landing_company] expected result=$result when onfido=$onfido_status idv=$idv_status manual=$manual_status $remark";

        $client->status->clear_poi_dob_mismatch;
        $client->status->clear_poi_name_mismatch;
    }

    # cleanup

    $client_mock->unmock_all;
};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

use Date::Utility;

use BOM::RPC::v3::Accounts;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;

my %rejected_reasons = %BOM::RPC::v3::Accounts::RejectedIdentityVerificationReasons;

subtest 'idv details' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    $client->email('idv+details@binary.com');
    $client->save;

    my $user = BOM::User->create(
        email    => 'idv+details@binary.com',
        password => 'Cookie'
    );
    $user->add_client($client);

    my $non_expired_date = Date::Utility->today->_plus_years(1);
    my $expired_date     = Date::Utility->today->_minus_years(1);

    my $tests = [{
            title    => 'documentless scenario',
            document => undef,
            check    => undef,
            result   => {
                submissions_left    => 2,
                last_rejected       => [],
                status              => 'none',
                reported_properties => {},
            }
        },
        {
            title    => 'verified - no expiration date',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => undef,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [],
                status              => 'verified',
                reported_properties => {},
            }
        },
        {
            title    => 'verified - non expired expiration date',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => $non_expired_date->date_yyyymmdd,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [],
                status              => 'verified',
                expiry_date         => $non_expired_date->epoch,
                reported_properties => {},
            }
        },
        {
            title    => 'verified but expired',
            document => {
                issuing_country          => 'us',
                document_number          => '1122334455',
                document_type            => 'ssn',
                document_expiration_date => $expired_date->date_yyyymmdd,
                status                   => 'verified',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [],
                status              => 'expired',
                expiry_date         => $expired_date->epoch,
                reported_properties => {},
            }
        },
        {
            title    => 'refuted',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'refuted',
                status_messages => '["UNDERAGE", "NAME_MISMATCH"]',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [map { $rejected_reasons{$_} } qw/UNDERAGE NAME_MISMATCH/],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'failed',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'failed',
                status_messages => '["UNDERAGE", "TEST"]',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [map { $rejected_reasons{$_} } qw/UNDERAGE/],
                status              => 'rejected',
                reported_properties => {},
            }
        },
        {
            title    => 'pending',
            document => {
                issuing_country => 'us',
                document_number => '1122334455',
                document_type   => 'ssn',
                status          => 'pending',
                status_messages => '["UNDERAGE", "TEST"]',
            },
            result => {
                submissions_left    => 2,
                last_rejected       => [],
                status              => 'pending',
                reported_properties => {},
            }
        },
    ];

    my $document;

    my $doc_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $doc_mock->mock(
        'get_last_updated_document',
        sub {
            return $document;
        });

    for my $test ($tests->@*) {
        my ($title, $doc_data, $check_data, $result, $rp) = @{$test}{qw/title document check result/};

        if ($doc_data) {
            $document = {
                user_id => $client->user->id,
                $doc_data->%*,
            };

        } else {
            $document = undef;
        }

        cmp_deeply BOM::RPC::v3::Accounts::_get_idv_service_detail($client), $result, "Expected result: $title";
    }

    $doc_mock->unmock_all;
};

done_testing();

use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Backoffice::VirtualStatus;

# remember to mock anything that would hit the DB as unit tests don't support DB access

my $client_mock = Test::MockModule->new('BOM::User::Client');
my $is_financial_assessment_complete;
$client_mock->mock(
    'is_financial_assessment_complete',
    sub {
        return $is_financial_assessment_complete;
    });
my $docs_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $expired;
$docs_mock->mock(
    'expired',
    sub {
        return $expired;
    });

$client_mock->mock(
    'status',
    sub {
        return bless +{}, 'BOM::User::Client::Status';
    });

my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
my $withdrawal_locked;
$status_mock->mock(
    'withdrawal_locked',
    sub {
        return $withdrawal_locked;
    });

my $cashier_locked;
$status_mock->mock(
    'cashier_locked',
    sub {
        return $cashier_locked;
    });

my $client = BOM::User::Client->rnew;
$client->broker('CR');
$client->residence('br');

subtest 'withdrawal locked' => sub {
    $withdrawal_locked                = undef;
    $is_financial_assessment_complete = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'No withdrawal locked needed';

    $withdrawal_locked                = undef;
    $expired                          = 0;
    $is_financial_assessment_complete = 0;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)},
        +{
        'Withdrawal Locked' => {
            last_modified_date => re('.*'),
            reason             => 'FA needs to be completed',
            staff_name         => "SYSTEM",
            status_code        => "withdrawal_locked",
            warning            => 'var(--color-red)',
        }
        },
        'Virtual withdrawal locked due to incomplete FA';

    $withdrawal_locked                = 1;
    $is_financial_assessment_complete = 0;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'Virtual withdrawal locked not needed as the real status is there';
};

subtest 'cashier locked' => sub {
    $cashier_locked = undef;
    $expired        = 0;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'No cashier locked needed';

    $cashier_locked = undef;
    $expired        = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)},
        +{
        'Cashier Locked' => {
            last_modified_date => re('.*'),
            reason             => 'POI has expired',
            staff_name         => "SYSTEM",
            status_code        => "cashier_locked",
            warning            => 'var(--color-red)',
        }
        },
        'Virtual cashier locked due to expired POI';

    $cashier_locked                   = 1;
    $expired                          = 1;
    $is_financial_assessment_complete = 0;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'Virtual cashier locked not needed as the real status is there';
};

done_testing;

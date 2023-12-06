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
my $outdated;
$docs_mock->mock(
    'expired',
    sub {
        return $expired;
    });
$docs_mock->mock(
    'outdated',
    sub {
        return $outdated;
    });

$client_mock->mock(
    'status',
    sub {
        return bless +{}, 'BOM::User::Client::Status';
    });

my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
my $withdrawal_locked;
my $mt5_withdrawal_locked;
$status_mock->mock(
    'withdrawal_locked',
    sub {
        return $withdrawal_locked;
    });
$status_mock->mock(
    'mt5_withdrawal_locked',
    sub {
        return $mt5_withdrawal_locked;
    });

my $cashier_locked;
$status_mock->mock(
    'cashier_locked',
    sub {
        return $cashier_locked;
    });

my $user_mock = Test::MockModule->new('BOM::User');
my $has_mt5_regulated_account;
$user_mock->mock(
    'has_mt5_regulated_account',
    sub {
        return $has_mt5_regulated_account;
    });

my $client = BOM::User::Client->rnew;
$client_mock->mock('user', sub { bless {}, 'BOM::User' });
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

subtest 'mt5 withdrawal locked' => sub {
    $mt5_withdrawal_locked     = undef;
    $expired                   = 0;
    $outdated                  = 0;
    $has_mt5_regulated_account = undef;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'No MT5 withdrawal locked needed';

    $mt5_withdrawal_locked     = undef;
    $expired                   = 0;
    $outdated                  = 0;
    $has_mt5_regulated_account = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'No MT5 withdrawal locked needed';

    $mt5_withdrawal_locked     = undef;
    $expired                   = 1;
    $outdated                  = 0;
    $has_mt5_regulated_account = 0;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'No MT5 withdrawal locked needed';

    $mt5_withdrawal_locked     = undef;
    $expired                   = 1;
    $outdated                  = 0;
    $has_mt5_regulated_account = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)},
        +{
        'MT5 Withdrawal Locked' => {
            last_modified_date => re('.*'),
            reason             => 'POI has expired',
            staff_name         => "SYSTEM",
            status_code        => "mt5_withdrawal_locked",
            warning            => 'var(--color-red)',
        }
        },
        'Virtual mt5 withdrawal locked due to expired POI';

    $mt5_withdrawal_locked     = undef;
    $expired                   = 0;
    $outdated                  = 1;
    $has_mt5_regulated_account = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)},
        +{
        'MT5 Withdrawal Locked' => {
            last_modified_date => re('.*'),
            reason             => 'POA is outdated',
            staff_name         => "SYSTEM",
            status_code        => "mt5_withdrawal_locked",
            warning            => 'var(--color-red)',
        }
        },
        'Virtual mt5 withdrawal locked due to outdated POA';

    $mt5_withdrawal_locked     = undef;
    $expired                   = 1;
    $outdated                  = 1;
    $has_mt5_regulated_account = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)},
        +{
        'MT5 Withdrawal Locked' => {
            last_modified_date => re('.*'),
            reason             => 'POA is outdated. POI has expired',
            staff_name         => "SYSTEM",
            status_code        => "mt5_withdrawal_locked",
            warning            => 'var(--color-red)',
        }
        },
        'Virtual mt5 withdrawal locked due to outdated POA';

    $mt5_withdrawal_locked     = 1;
    $has_mt5_regulated_account = 1;
    $expired                   = 1;
    $outdated                  = 1;
    cmp_deeply + {BOM::Backoffice::VirtualStatus::get($client)}, +{}, 'Virtual withdrawal locked not needed as the real status is there';
};

done_testing;

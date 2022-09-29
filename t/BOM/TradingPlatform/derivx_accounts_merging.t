use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Warn;
use Log::Any::Test;
use Log::Any qw($log);
use Log::Any::Adapter (qw(Stderr), log_level => 'warn');
use BOM::TradingPlatform::DXAccountsMerging;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::Config::Runtime;
use YAML::XS qw(LoadFile DumpFile);

my $instance;
my $merging_module       = Test::MockModule->new('BOM::TradingPlatform::DXAccountsMerging');
my $dx                   = Test::MockModule->new('BOM::TradingPlatform::DXTrader');
my $transfer_limits      = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade');
my $max_transfer_limit   = $transfer_limits->{USD}->{max};
my $call_get_dx_accounts = 0;
my $check_withdraw       = 0;
my $check_deposit        = 0;
my $check_archive        = 0;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    loginid     => 'CR000000',
    broker_code => 'CR',
    email       => 'testing@test.com',
});

my $user = BOM::User->create(
    email    => $client->email,
    password => 'test',
)->add_client($client);

subtest 'derivx accounts merging' => sub {

    # No accounts to process

    lives_ok { $instance = BOM::TradingPlatform::DXAccountsMerging->new(account_type => 'real') } 'Create new instance';

    $merging_module->mock(
        'get_dx_accounts',
        sub {
            $call_get_dx_accounts = 1;
            return [];
        });

    $instance->merge_accounts;

    ok($call_get_dx_accounts == 1, "Subroutine called");
    $log->contains_ok(qr/No real accounts to process/, "Correct log message when no accounts have been found");

    $merging_module->unmock_all();
    $log->clear;

    # Account with 0 balance

    $dx->mock(
        'archive_dx_account',
        sub {
            $check_archive = 1;
            return 1;
        },
        'withdraw',
        sub {
            $check_withdraw = 1;
            return {};
        },
        'deposit',
        sub {
            $check_deposit = 1;
            $merging_module->redefine(
                'get_dx_account_details',
                sub {
                    return (0, 'USD');
                });
            return {};
        });

    $merging_module->redefine(
        'get_dx_accounts',
        sub {
            return [[1, 'CR000000', 'DX111111', 'DX222222']];
        },
        'get_dx_account_details',
        sub {
            return (0, 'USD');
        });

    $instance->merge_accounts;

    $log->contains_ok(qr/Real account 'DX222222' has 0 USD balance/, "Correct log message when an account has 0 balance");

    $log->clear;

    # Daily transfer limit reached

    $merging_module->redefine(
        'get_dx_account_details',
        sub {
            return (10, 'USD');
        });

    $user->daily_transfer_incr('dxtrade');
    my $daily_transfer_limit = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade;
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(1);
    $instance->merge_accounts;

    $log->contains_ok(qr/Daily transfer limit for user 1 has been reached \[1\/1\]. Remaining balance on DerivX : 10 USD/,
        "Correct log message when daily transfer limit reached");

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade($daily_transfer_limit);
    $log->clear;

    # Balance transfer + archival

    $instance->merge_accounts;
    $log->contains_ok(qr/Found real financial account 'DX222222' with 10 USD/, "Correct log message when an account with balance is found");

    ok($check_withdraw == 1, "Withdraw function called");
    $log->contains_ok(qr/Withdrew 10.00 USD from DX222222 to CR000000/, "Correct log message when withdrawing balance");

    ok($check_deposit == 1, "Deposit function called");
    $log->contains_ok(qr/Deposited 10.00 USD to DX111111/, "Correct log message when depositing");

    ok($check_archive == 1, "Archive function called");
    $log->contains_ok(qr/Account 'DX222222' has been successfully archived/, "Correct log message when account is archived");

    # Balance split if more than maximum transfer limit

    my $test_balance = 4000;
    my $old_balance  = $test_balance;
    my $new_balance  = 0;
    my $try          = 1;

    $merging_module->redefine(
        'get_dx_account_details',
        sub {
            return ($test_balance, 'USD');
        });

    $dx->redefine(
        'deposit',
        sub {
            if ($old_balance > $max_transfer_limit) {
                $old_balance = $old_balance - $max_transfer_limit;
                $new_balance = $new_balance + $max_transfer_limit;
            } else {
                $new_balance = $new_balance + $old_balance;
                $old_balance = $old_balance - $old_balance;
            }

            $merging_module->redefine(
                'get_dx_account_details',
                sub {
                    return ($old_balance, 'USD');
                });
            $try++;
            return {};
        });

    $instance->merge_accounts;
    $log->contains_ok(qr/Found real financial account 'DX222222' with 4000 USD/, "Correct log message when an account with balance is found");
    $log->contains_ok(qr/Account 'DX222222' has a balance which is bigger than the maximum transfer limit \(2500\), will split/,
        "Correct log message when balance needs to be split");
    $log->contains_ok(qr/Withdrew 2500.00 USD from DX222222 to CR000000/, "Correct log message when withdrawing first part of the balance");
    $log->contains_ok(qr/Deposited 2500.00 USD to DX111111/,              "Correct log message when depositing first part of the balance");
    $log->contains_ok(qr/Withdrew 1500.00 USD from DX222222 to CR000000/, "Correct log message when withdrawing second part of the balance");
    $log->contains_ok(qr/Deposited 1500.00 USD to DX111111/,              "Correct log message when depositing second part of the balance");

    ok($old_balance == 0,             "Correct balance after withdrawal");
    ok($new_balance == $test_balance, "Correct balance after deposit");

    $log->clear;
    $merging_module->unmock_all();
    $dx->unmock_all();
};

subtest 'handle_failed_deposits' => sub {

    # Deleting empty file

    my $test_file_name = 'failed_deposits_test.yml';

    my $data          = {};
    my $check_archive = 0;
    my $check_deposit = 0;

    lives_ok { $instance = BOM::TradingPlatform::DXAccountsMerging->new(account_type => 'real', failed_deposits_file => $test_file_name) }
    'Create new instance';

    DumpFile($test_file_name, $data);

    $instance->process_failed_deposits;

    is(-e $test_file_name, undef, "Empty file correctly deleted");

    # Deposit error

    $data = {
        amount            => 100,
        currency          => 'EUR',
        to_account        => 'DX123456',
        cr_account        => 'CR000000',
        financial_account => 'DX789012'
    };

    $merging_module->mock(
        'deposit_to_synthetic',
        sub {
            return "Error message";
        });

    DumpFile($test_file_name, {failed_deposit_1 => $data});

    $instance->process_failed_deposits;

    $log->contains_ok(qr/Reading failed_deposit_1/,                              "Correct log message when reading the file");
    $log->contains_ok(qr/Depositing 100 EUR to DX123456 failed : Error message/, "Correct log message in case of deposit error");

    is(-e $test_file_name, 1, "File is still intact after the error");

    $log->clear;

    # Read line and deposit

    $merging_module->redefine(
        'deposit_to_synthetic',
        sub {
            $check_deposit = 1;
            $log->infof("Deposited %s %s to %s", $data->{amount}, $data->{currency}, $data->{to_account});
            return;
        });

    $dx->mock(
        'archive_dx_account',
        sub {
            $check_archive = 1;
            return 1;
        });

    $instance->process_failed_deposits;

    ok($check_deposit == 1, "Deposit function called");
    $log->contains_ok(qr/Deposited 100 EUR to DX123456/, "Correct log message when depositing");

    ok($check_archive == 1, "Archive function called");
    $log->contains_ok(qr/Account 'DX789012' has been successfully archived/, "Correct log message when account is archived");

    is(-e $test_file_name, undef, "Empty file correctly deleted");

    $log->clear;
    $merging_module->unmock_all();
};

done_testing();

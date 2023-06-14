use strict;
use warnings;
no indirect;

use Test::Most;
use Test::MockModule;
use Future::AsyncAwait;
use Test::Fatal qw/exception/;
use Test::More;
use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;

my $mock            = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject');
my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => 'cr');

my $db_reject_withdrawal_called_times = 0;

sub mock_my_methods {

    my %details = @_;

    $mock->mock(
        db_load_locked_crypto_withdrawals => sub {

            # necessary at least one to trigger processing
            return $details{locked_withdrawals} // [{
                    binary_user_id                 => 1,
                    client_loginid                 => 'CR90000000',
                    total_withdrawal_amount_in_usd => 30,
                    amount_in_usd                  => 5,
                    currency_code                  => 'BTC'
                }];
        },
        db_load_total_withdrawals_today => sub {

            return [{
                    id             => 1,
                    client_loginid => 'CR90000000',
                    amount         => 30,
                    currency_code  => 'BTC'
                }];
        },
        db_load_withdrawals_per_user_in_usd => sub {

            return [{
                    binary_user_id                 => 1,
                    client_loginid                 => 'CR90000000',
                    total_withdrawal_amount_in_usd => 30,
                    amount_in_usd                  => 5,
                    currency_code                  => 'BTC'
                }];
        },
        db_reject_withdrawal => sub {
            $db_reject_withdrawal_called_times += 1;
            return {};
        },
        csv_export => sub {
            # nope
        },
        send_email => sub {
            # nope
        },
        user_activity => sub {
            return $details{user_activity} // {
                tag                       => 'test',
                reject_reason             => 'highest_deposit_method_is_not_crypto',
                suggested_withdraw_method => "Skrill",
                auto_reject               => 0
            };
        });

    return $mock;
}

subtest "BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject" => sub {

    subtest "do not auto reject for dry runs" => sub {

        mock_my_methods(
            user_activity => {
                tag                       => 'doesnt matter',
                reject_reason             => 'highest_deposit_method_is_not_crypto',
                suggested_withdraw_method => "Skrill",
                auto_reject               => 1
            });
        $auto_reject_obj->run(is_dry_run => 1);
        is($db_reject_withdrawal_called_times, 0, 'the payment has not been rejected for dry run');

        $mock->unmock_all();

    };

    subtest "do not auto reject even if enable_reject is set to 1 but transaction is set not to auto_reject" => sub {

        mock_my_methods(
            user_activity => {
                tag                       => 'doesnt matter',
                reject_reason             => 'highest_deposit_method_is_not_crypto',
                suggested_withdraw_method => "Skrill",
                auto_reject               => 0
            });
        $auto_reject_obj->run(
            is_dry_run => 0,
        );
        is($db_reject_withdrawal_called_times, 0, 'the payment has not been rejected even with the flag `is_dry_run` set to 0');

        $mock->unmock_all();

    };

    subtest "Auto reject the transaction if auto_reject and enable_reject is set to 1" => sub {
        $db_reject_withdrawal_called_times = 0;

        mock_my_methods(
            user_activity => {
                tag                       => 'doesnt matter',
                reject_reason             => 'highest_deposit_method_is_not_crypto',
                suggested_withdraw_method => "Skrill",
                auto_reject               => 1
            });
        $auto_reject_obj->run(is_dry_run => 0);

        is($db_reject_withdrawal_called_times, 1, 'the payment has been auto rejected since auto_reject is enabled and is_dry_run is disabled');

        $mock->unmock_all();

    };
};

done_testing;

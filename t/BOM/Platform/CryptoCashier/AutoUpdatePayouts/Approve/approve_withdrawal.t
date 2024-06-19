use strict;
use warnings;
no indirect;

use Test::Most;
use Test::MockModule;
use Test::Fatal qw/exception/;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

my $mock             = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve');
my $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(broker_code => 'cr');

my $db_approve_withdrawal_called_times = 0;

sub mock_clientdb {
    my %details = @_;

    $mock->mock(
        db_load_locked_crypto_withdrawals => sub {
            # necessary at least one to trigger processing
            return $details{locked_withdrawals} // [{
                    binary_user_id                 => 1,
                    client_login_id                => 'CR90000000',
                    total_withdrawal_amount_in_usd => 30,
                    amount_in_usd                  => 5,
                    currency_code                  => 'ETH'
                }];
        },
        db_load_total_withdrawals_today => sub {
            return [{
                    id             => 1,
                    client_loginid => 'CR90000000',
                    amount         => 30,
                    currency_code  => 'ETH'
                }];
        },
        db_load_withdrawals_per_user_in_usd => sub {
            return [{
                    binary_user_id                 => 1,
                    client_login_id                => 'CR90000000',
                    total_withdrawal_amount_in_usd => 30,
                    amount_in_usd                  => 5,
                    currency_code                  => 'ETH'
                }];
        },
        db_approve_withdrawal => sub {
            $db_approve_withdrawal_called_times += 1;
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
                auto_approve => 0,
                tag          => 'does not matter'
            };
        });

    return $mock;
}

subtest "BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve" => sub {
    subtest 'does not approve the payout when the user is set to not autoapprove anything' => sub {
        $db_approve_withdrawal_called_times = 0;

        mock_clientdb(
            user_activity => {
                auto_approve => 0,
                tag          => 'does not really matter, it just to avoid code warnings'
            });

        $auto_approve_obj->run();
        is($db_approve_withdrawal_called_times, 0, 'the payout has not been approved');

        $db_approve_withdrawal_called_times = 0;

        $auto_approve_obj->run(is_dry_run => 0);

        is($db_approve_withdrawal_called_times, 0, 'the payout has not been approved, even with the flag `is_dry_run` => 0');

        $mock->unmock_all();
    };

    subtest 'does not approve the payout when the user is set to autoapprove payouts but flag `is_dry_run` is set to 1' => sub {
        $db_approve_withdrawal_called_times = 0;

        mock_clientdb(
            user_activity => {
                auto_approve => 1,
                tag          => 'does not really matter, it just to avoid code warnings'
            });

        $auto_approve_obj->run(is_dry_run => 1);
        is($db_approve_withdrawal_called_times, 0, 'the payout has not been approved');

        $mock->unmock_all();
    };

    subtest 'approves the payout when the user is set to autoapprove payouts and the flag `is_dry_run => 0` has been set to 0' => sub {
        $db_approve_withdrawal_called_times = 0;

        mock_clientdb(
            user_activity => {
                auto_approve => 1,
                tag          => 'does not really matter, it just to avoid code warnings'
            });

        $auto_approve_obj->run(is_dry_run => 0);
        is($db_approve_withdrawal_called_times, 1, 'the payout has been approved, yay!');

        $mock->unmock_all();
    };

    subtest 'dies when there is no exchange rates' => sub {
        mock_clientdb(
            locked_withdrawals => [{
                    binary_user_id  => 1,
                    client_login_id => 'CR90000000',
                    amount_in_usd   => undef,
                    currency_code   => 'ETH'
                }
            ],
            user_activity => {
                auto_approve => 1,
                tag          => 'does not matter'
            });

        like(
            exception {
                $auto_approve_obj->run(is_dry_run => 0);
            },
            qr/The crypto autoapproval script tried to process an withdrawal with no exchange rates. Please raise it with the back-end team/
        );
    };
};

done_testing;

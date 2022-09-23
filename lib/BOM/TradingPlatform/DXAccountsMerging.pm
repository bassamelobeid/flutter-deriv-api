package BOM::TradingPlatform::DXAccountsMerging;

use strict;
use warnings;

use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use Log::Any qw($log);
use BOM::Database::UserDB;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::TradingPlatform::DXTrader;
use BOM::User::Client;
use BOM::TradingPlatform;
use BOM::Rules::Engine;
use Object::Pad;
use Syntax::Keyword::Try;
use YAML::XS                         qw(LoadFile DumpFile);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw(financialrounding);

class BOM::TradingPlatform::DXAccountsMerging {

    my ($account_type, $failed_deposits_file, $settings);

    BUILD {
        my %runtime_args = @_;
        $settings = {
            account_type         => 'demo',
            failed_deposits_file => 'failed_deposits.yml'
        };
        %$settings = (%$settings, %runtime_args);

        $account_type         = $settings->{account_type};
        $failed_deposits_file = $settings->{failed_deposits_file} // '';
    }

    method accounts_merging {
        if ($failed_deposits_file) {
            $self->process_failed_deposits;
        } else {
            $self->merge_accounts;
        }
    }

    method process_failed_deposits {
        unless (-e $failed_deposits_file) {
            die "File '$failed_deposits_file' does not exist";
        }

        my $data = LoadFile($failed_deposits_file);

        foreach my $key (sort keys %$data) {
            try {
                my $values = %$data{$key};

                $log->infof("Reading %s with %s", $key, $values);

                my $client = BOM::User::Client->new({loginid => $values->{cr_account}});

                my $rule_engine = BOM::Rules::Engine->new(client => $client);

                my $dx = BOM::TradingPlatform->new(
                    rule_engine => $rule_engine,
                    platform    => 'dxtrade',
                    client      => $client
                );

                my $daily_transfer_count = $client->user->daily_transfer_count('dxtrade');
                my $daily_transfer_limit = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade;

                if ($daily_transfer_count == $daily_transfer_limit) {
                    $log->warnf("Daily transfer limit for user %s has been reached [%s/%s].",
                        $client->user_id, $daily_transfer_count, $daily_transfer_limit);
                    next;
                }

                my $deposit_result = $self->deposit_to_synthetic($dx, $values);

                if ($deposit_result) {
                    $log->errorf("Depositing %s %s to %s failed : %s", $values->{amount}, $values->{currency}, $values->{to_account},
                        $deposit_result);
                } else {
                    delete $data->{$key};
                    DumpFile($failed_deposits_file, $data);

                    $dx->archive_dx_account($account_type, $values->{financial_account});
                    $log->infof("Account '%s' has been successfully archived", $values->{financial_account});

                    $dx->update_details($account_type, $values->{to_account});
                    $log->infof("'market_type' attribute and 'Trading' category for '%s' have been successfully updated", $values->{to_account});
                }

                $log->info("-------");
            } catch ($e) {
                $log->warnf("An error has occured while processing '%s' : %s", $key, $e);
            }
        }

        # Delete file when no rows left to process
        $data = LoadFile($failed_deposits_file);

        unless (scalar %$data) {
            unlink($failed_deposits_file);
            $log->infof("No rows to process, file '%s' has been deleted", $failed_deposits_file);
        }
    }

    method merge_accounts {

        my $dx_accounts = $self->get_dx_accounts($account_type);

        unless (scalar @$dx_accounts) {
            $log->warnf("No %s accounts to process", $account_type);
            return;
        }

        foreach my $dx_account (@$dx_accounts) {
            my ($account_id, $cr_account, $synthetic_account, $financial_account) = $dx_account->@*;

            try {
                my $client = BOM::User::Client->new({loginid => $cr_account});

                if ($client->currency ne 'USD') {
                    my $sibling_accounts = $client->get_siblings_information;

                    foreach my $sibling_account (keys %$sibling_accounts) {
                        if ((index($sibling_account, 'CR') != -1) and $sibling_accounts->{$sibling_account}->{currency} eq 'USD') {
                            $cr_account = $sibling_account;
                            $client     = BOM::User::Client->new({loginid => $cr_account});
                            last;
                        }
                    }
                }

                my $transfer_limits      = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade');
                my $daily_transfer_count = $client->user->daily_transfer_count('dxtrade');
                my $daily_transfer_limit = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade;

                my $rule_engine = BOM::Rules::Engine->new(client => $client);

                my $dx = BOM::TradingPlatform->new(
                    rule_engine => $rule_engine,
                    platform    => 'dxtrade',
                    client      => $client
                );

                my ($balance, $currency) = $self->get_dx_account_details($dx, $financial_account);

                if ($balance && $balance > 0) {
                    $log->infof("Found %s financial account '%s' with %s %s", $account_type, $financial_account, $balance, $currency);

                    if ($account_type eq 'real') {
                        my $max_transfer_limit = $transfer_limits->{$currency}->{max};

                        while ($balance > 0) {

                            if ($daily_transfer_count == $daily_transfer_limit) {
                                $log->warnf("Daily transfer limit for user %s has been reached [%s/%s]. Remaining balance on DerivX : %s %s",
                                    $account_id, $daily_transfer_count, $daily_transfer_limit, $balance, $currency);
                                last;
                            }

                            if ($balance > $max_transfer_limit) {
                                $log->infof("Account '%s' has a balance which is bigger than the maximum transfer limit (%s), will split",
                                    $financial_account, $max_transfer_limit);

                                $balance = $max_transfer_limit;
                            }

                            $balance = financialrounding('amount', $currency, $balance);

                            $dx->withdraw(
                                amount       => $balance,
                                currency     => $currency,
                                from_account => $financial_account,
                                to_account   => $cr_account
                            );

                            $log->infof("Withdrew %s %s from %s to %s", $balance, $currency, $financial_account, $cr_account);

                            $balance = financialrounding('amount', $client->currency, convert_currency($balance, $currency, $client->currency));

                            if ($client->currency ne $currency) {
                                $log->infof(
                                    "Main Deriv account %s is in %s currency - after the conversion, 
                                the amount to deposit is %s %s", $cr_account, $client->currency, $balance, $client->currency
                                );
                            }

                            my $deposit_data = {
                                cr_account        => $cr_account,
                                currency          => $client->currency,
                                amount            => $balance,
                                to_account        => $synthetic_account,
                                financial_account => $financial_account
                            };

                            my $deposit_result = $self->deposit_to_synthetic($dx, $deposit_data);

                            if ($deposit_result) {
                                my ($financial_balance, $financial_currency) = $self->get_dx_account_details($dx, $financial_account);

                                $self->write_to_file($deposit_data);

                                die
                                    "Depositing $balance $currency to $synthetic_account failed : $deposit_result. Financial account $financial_account has $financial_balance $financial_currency remaining";
                            }

                            # Get the updated balance and the daily transfer limit
                            ($balance) = $self->get_dx_account_details($dx, $financial_account);
                            $daily_transfer_count = $client->user->daily_transfer_count('dxtrade');

                            last if $balance == 0;
                        }
                    }
                } else {
                    $log->infof("%s account '%s' has 0 %s balance", ucfirst($account_type), $financial_account, $currency);
                }

                try {
                    $dx->archive_dx_account($account_type, $financial_account);
                    $log->infof("Account '%s' has been successfully archived", $financial_account);

                    $dx->update_details($account_type, $synthetic_account);
                    $log->infof("'market_type' and 'Trading' category for '%s' have been successfully updated", $synthetic_account);
                } catch ($e) {
                    $log->warnf("An error has occured while archiving account '%s' : %s", $financial_account, $e);
                    next;
                }
            } catch ($e) {
                $log->warnf("An error has occured while processing account '%s' : %s", $account_id, $e);
                next;
            }
            $log->info("-------");
        }
    }

    method deposit_to_synthetic {
        my ($dx, $data) = @_;

        # Get synthetic account balance before making the deposit to be able to verify it in case of failure
        my ($balance_before) = $self->get_dx_account_details($dx, $data->{to_account});

        try {
            $dx->deposit(%$data);
        } catch ($e) {
            my ($balance_after) = $self->get_dx_account_details($dx, $data->{to_account});

            if ($balance_before == $balance_after) {
                $e = $e->{error_code} if ref($e) eq "HASH";
                return $e;
            }
        }

        $log->infof("Deposited %s %s to %s", $data->{amount}, $data->{currency}, $data->{to_account});
        return;
    }

    method write_to_file {

        my ($data) = @_;

        my $filename = './failed_deposits.yml';

        unless (-e $filename) {
            DumpFile($filename, {failed_deposit_1 => $data});
            $log->infof("Recorded data to %s file : %s", $filename, $data);
            return;
        }

        my $failed_deposits = LoadFile($filename);

        my $new_count = scalar(%{$failed_deposits}) + 1;

        my %deposit_data = ("failed_deposit_$new_count" => $data);

        %{$failed_deposits} = (%{$failed_deposits}, %deposit_data);

        DumpFile($filename, $failed_deposits);

        $log->infof("Recorded data to %s file : %s", $filename, $data);

        return;
    }

    method get_dx_accounts {
        my ($account_type) = @_;

        my $user_db = BOM::Database::UserDB::rose_db();

        # Some clients only have VRTC accounts, so we need to include
        # them in the query
        my $vrtc_query = $account_type eq 'demo' ? " OR loginid LIKE 'VRTC%'" : "";

        my $dx_accounts = $user_db->dbic->run(
            fixup => sub {
                my $query = $_->prepare(
                    "SET statement_timeout = 0;
                    WITH 
                        financial_accounts AS (
                            SELECT binary_user_id, loginid 
                            FROM users.loginid 
                            WHERE status IS NULL 
                            AND platform = 'dxtrade' 
                            AND account_type = ? 
                            AND attributes->> 'market_type' = 'financial'), 
                        synthetic_accounts AS (
                            SELECT binary_user_id, loginid 
                            FROM users.loginid 
                            WHERE status IS NULL 
                            AND platform = 'dxtrade' 
                            AND account_type = ? 
                            AND attributes->> 'market_type' = 'synthetic'), 
                        cr_accounts AS (
                            SELECT DISTINCT ON(binary_user_id) loginid, binary_user_id 
                            FROM users.loginid 
                            WHERE loginid LIKE 'CR%' $vrtc_query
                            ORDER BY binary_user_id)

                     SELECT cr.binary_user_id, 
                            cr.loginid AS cr_account, 
                            synthetic_accounts.loginid AS synthetic_loginid, 
                            financial_accounts.loginid AS financial_loginid 
                       FROM cr_accounts AS cr
                       JOIN synthetic_accounts
                            ON cr.binary_user_id = synthetic_accounts.binary_user_id
                       JOIN financial_accounts
                            ON cr.binary_user_id = financial_accounts.binary_user_id"
                );
                $query->execute($account_type, $account_type);
                $query->fetchall_arrayref();
            });

        return $dx_accounts;
    }

    method get_dx_account_details {
        my ($dx, $account) = @_;
        my $dx_accounts = $dx->get_accounts;
        my ($dxf) = grep { $account eq $_->{account_id} } @$dx_accounts;

        return ($dxf->{balance}, $dxf->{currency});
    }
}

1;

#!/etc/rmg/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use Future::AsyncAwait;
use Pod::Usage;
use Getopt::Long;
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use Log::Any qw($log);
use BOM::Database::UserDB;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::User::Client;
use BOM::TradingPlatform;
use BOM::Rules::Engine;
use Object::Pad;
use Syntax::Keyword::Try;
use YAML::XS                         qw(LoadFile DumpFile);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw(financialrounding);
use WebService::Async::DevExperts::Dxsca::Client;
use WebService::Async::DevExperts::DxWeb::Client;
use Future::Utils qw( fmap_void try_repeat);
use Date::Utility;
use Net::Async::Redis;
use BOM::Config::Redis;
use DataDog::DogStatsd::Helper qw(stats_inc);

=head1 NAME

derivx_accounts_merging.pl

=head1 SYNOPSIS

./derivx_accounts_merging.pl [options] 

=head1 NOTE

This script will transfer balance from financial to synthetic accounts (real only) and
change financial accounts' statuses ('archived' in our DB and 'TERMINATED' in DerivX) 

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

MT5 server type ('real' or 'demo')

=item B<-f>, B<--file>

File with failed deposits to process

=item B<-c>, B<--concurrent_calls>

Number of concurrent calls to apply to the script (default : 6)

=item B<-s>, B<--status_filter>

Status filter for the SQL query (default: 1)

=item B<-d>, B<--delay_processing>

(FOR TEST ONLY) Delay processing of an account (in seconds) in order to check if new account 
creation and fund transfers are disabled while the merging is taking place

=back

=cut

my $help                 = 0;
my $account_type         = 'demo';
my $failed_deposits_file = '';
my $concurrent_calls     = 2;
my $status_filter        = 1;
my $delay_processing     = 0;

GetOptions(
    'a|account_type=s'         => \$account_type,
    'f|failed_deposits_file=s' => \$failed_deposits_file,
    'c|concurrent_calls=i'     => \$concurrent_calls,
    's|status_filter=i'        => \$status_filter,
    'd|delay_processing=i'     => \$delay_processing,
    'h|help!'                  => \$help,
);

pod2usage(1) if $help;

my %clients;
my $loop               = IO::Async::Loop->new;
my $derivx_config_file = '/etc/rmg/devexperts.yml';
my $config             = LoadFile($derivx_config_file);

my @servers = ('demo', 'real');

for my $server_type (@servers) {
    $loop->add(
        $clients{$server_type} = WebService::Async::DevExperts::DxWeb::Client->new(
            host    => $config->{servers}{$server_type}{host},
            port    => $config->{servers}{$server_type}{port},
            user    => $config->{servers}{$server_type}{user},
            pass    => $config->{servers}{$server_type}{pass},
            timeout => 15
        ));
}

$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => BOM::Config::Redis::redis_config('rpc', 'write')->{uri},
    ));

async sub accounts_merging {
    if ($failed_deposits_file) {
        await process_failed_deposits();
    } else {
        await merge_accounts();
    }
}

async sub archive_dx_account {

    my ($financial_account) = @_;

    await $clients{$account_type}->account_update(
        clearing_code => 'default',
        account_code  => $financial_account,
        status        => 'TERMINATED'
    );

    my $user_db = BOM::Database::UserDB::rose_db();

    $user_db->dbic->run(
        fixup => sub {
            $_->do(
                "UPDATE users.loginid 
                    SET status = 'archived' 
                    WHERE loginid = ?",
                undef,
                $financial_account
            );
        });

    $log->infof("Account '%s' has been successfully archived", $financial_account);
    stats_inc("derivx.merging.archival.success", {tags => ["account:" . $financial_account]});
}

async sub update_details {

    my ($synthetic_account) = @_;

    await $clients{$account_type}->account_category_set(
        clearing_code => 'default',
        account_code  => $synthetic_account,
        category_code => "Trading",
        value         => "CFD",
    );

    my $user_db = BOM::Database::UserDB::rose_db();

    $user_db->dbic->run(
        fixup => sub {
            $_->do(
                "UPDATE users.loginid 
                    SET attributes = jsonb_set(attributes, '{market_type}', '\"all\"') 
                    WHERE loginid = ?",
                undef,
                $synthetic_account
            );
        });

    $log->infof(
        "%s 'market_type' and 'Trading' category for '%s' have been successfully updated",
        Date::Utility->new->db_timestamp,
        $synthetic_account
    );
    stats_inc("derivx.merging.update.success", {tags => ["account:" . $synthetic_account]});
}

async sub process_failed_deposits {
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

            my $deposit_result = await deposit_to_synthetic($dx, $values);

            if ($deposit_result) {
                $log->errorf("Depositing %s %s to %s failed : %s", $values->{amount}, $values->{currency}, $values->{to_account}, $deposit_result);
            } else {
                delete $data->{$key};
                DumpFile($failed_deposits_file, $data);

                await archive_dx_account($values->{financial_account});
                await update_details($values->{to_account});
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

async sub process_account {
    my $dx_account = shift;

    my ($account_id, $cr_account, $synthetic_account, $financial_account) = $dx_account->@*;

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

    my ($balance, $currency);

    try {
        ($balance, $currency) = await get_dx_account_details($financial_account);
    } catch ($e) {
        die "$e. No operations done at this stage";
    }

    if ($balance && $balance > 0) {
        $log->infof("Found %s financial account '%s' with %s %s", $account_type, $financial_account, $balance, $currency);
        stats_inc("derivx.merging.processing", {tags => ["account:" . $financial_account, "amount:" . $balance . " " . $currency]});

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

                try {
                    $dx->withdraw(
                        amount       => $balance,
                        currency     => $currency,
                        from_account => $financial_account,
                        to_account   => $cr_account
                    );
                } catch ($e) {
                    die "$e. Tried to withdraw $balance $currency from $financial_account to $cr_account. The account has not been archived.";
                }

                $log->infof("Withdrew %s %s from %s to %s", $balance, $currency, $financial_account, $cr_account);
                stats_inc("derivx.merging.withdrawal",
                    {tags => ["source_account:" . $financial_account, "target_account:" . $cr_account, "amount:" . $balance . " " . $currency]});

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

                my $deposit_result;

                try {
                    $deposit_result = await deposit_to_synthetic($dx, $deposit_data);
                } catch ($e) {
                    write_to_file($deposit_data);
                    die "$e. Tried to deposit $balance $client->currency to $synthetic_account. The account has not been archived.";
                }

                if ($deposit_result) {
                    my ($financial_balance, $financial_currency);

                    try {
                        ($financial_balance, $financial_currency) = await get_dx_account_details($financial_account);
                        write_to_file($deposit_data);
                    } catch ($e) {
                        die "$e. Some balance still needs to be transferred and account still needs to get archived.";
                    }

                    die
                        "Depositing $balance $currency to $synthetic_account failed : $deposit_result. Financial account $financial_account has $financial_balance $financial_currency remaining";
                }

                # Get the updated balance and the daily transfer limit
                try {
                    ($balance) = await get_dx_account_details($financial_account);
                } catch ($e) {
                    die "$e. Some balance still needs to be transferred and account still needs to get archived.";
                }

                $daily_transfer_count = $client->user->daily_transfer_count('dxtrade');

                last if $balance == 0;
            }
        }
    } else {
        $log->infof("%s account '%s' has 0 %s balance", ucfirst($account_type), $financial_account, $currency);
        stats_inc("derivx.merging.processing", {tags => ["account:" . $financial_account, "amount:0 " . $currency]});
    }

    try {
        await archive_dx_account($financial_account);
        await update_details($synthetic_account);
    } catch ($e) {
        die "$e. Money transfer should be complete but account archival failed";
    }
}

async sub merge_accounts {

    my $dx_accounts = get_dx_accounts($account_type);

    unless (scalar @$dx_accounts) {
        $log->warnf("No %s accounts to process", $account_type);
        return;
    }

    my $counter     = 0;
    my $epoch_start = Date::Utility->new->epoch;

    await fmap_void(
        async sub {
            my $dx_account = shift;

            my ($account_id, $cr_account, $synthetic_account, $financial_account) = $dx_account->@*;

            $log->infof("%s processing client %s", Date::Utility->new->db_timestamp, $account_id);

            await $redis->sadd('LOCK_DX_ACCOUNT_WHILE_MERGING', $cr_account);

            await $loop->delay_future(after => $delay_processing);

            try {
                await process_account($dx_account);
                stats_inc("derivx.merging.success", {tags => ["client:$account_id"]});
            } catch ($e) {
                $log->warnf("An error has occured when processing client '%s' : %s", $account_id, $e);
                stats_inc("derivx.merging.failure", {tags => ["client:$account_id", "error:$e"]});
            }

            await $redis->srem('LOCK_DX_ACCOUNT_WHILE_MERGING', $cr_account);

            $log->info("-------");
            $counter++;

            if ($counter % 100 == 0) {
                my $epoch_end = Date::Utility->new->epoch;
                $log->infof("Processed %s accounts, %s seconds have elapsed", $counter, ($epoch_end - $epoch_start));
            }
        },
        foreach    => $dx_accounts,
        concurrent => $concurrent_calls
    );
}

async sub deposit_to_synthetic {
    my ($dx, $data) = @_;

    # Get synthetic account balance before making the deposit to be able to verify it in case of failure
    my ($balance_before) = await get_dx_account_details($data->{to_account});

    try {
        $dx->deposit(%$data);
    } catch ($e) {
        my ($balance_after) = await get_dx_account_details($data->{to_account});

        if ($balance_before == $balance_after) {
            $e = $e->{error_code} if ref($e) eq "HASH";
            die $e;
        }
    }

    $log->infof("Deposited %s %s to %s", $data->{amount}, $data->{currency}, $data->{to_account});
    stats_inc("derivx.merging.deposit", {tags => ["account:" . $data->{to_account}, "amount:" . $data->{amount} . " " . $data->{currency}]});
    return undef;
}

sub write_to_file {

    my ($data) = @_;

    my $filename = '/var/lib/binary/failed_deposits.yml';

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

sub get_dx_accounts {
    my ($account_type) = @_;

    my $user_db = BOM::Database::UserDB::rose_db();

    # Some clients only have VRTC accounts, so we need to include
    # them in the query
    my $vrtc_query   = $account_type eq 'demo' ? " OR loginid LIKE 'VRTC%'" : "";
    my $status_query = $status_filter eq 1     ? " AND status IS NULL "     : "";

    my $dx_accounts = $user_db->dbic->run(
        fixup => sub {
            my $query = $_->prepare(
                "SET statement_timeout = 0;
                WITH 
                    financial_accounts AS (
                        SELECT binary_user_id, loginid 
                        FROM users.loginid 
                        WHERE platform = 'dxtrade'
                        $status_query
                        AND account_type = ? 
                        AND attributes->> 'market_type' = 'financial'), 
                    synthetic_accounts AS (
                        SELECT binary_user_id, loginid 
                        FROM users.loginid 
                        WHERE platform = 'dxtrade'
                        $status_query
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

async sub get_dx_account_details {
    my ($account) = @_;

    my $dx_accounts = await $clients{$account_type}->account_get(
        clearing_code => 'default',
        account_code  => $account,
    );

    # Position of 'Balance' and 'Currency' in hash
    return ($dx_accounts->[9], $dx_accounts->[8]);
}

await accounts_merging();

1;

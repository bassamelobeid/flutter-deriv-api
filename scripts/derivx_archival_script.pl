use strict;
use warnings;

use WebService::Async::DevExperts::Dxsca::Client;
use WebService::Async::DevExperts::DxWeb::Client;
use Future::Utils qw( fmap_void );
use Future::AsyncAwait;
use YAML::XS qw(LoadFile);
use IO::Async::Loop;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use BOM::Database::UserDB;
use BOM::Config;
use Date::Utility;
use Pod::Usage;
use Getopt::Long;
use BOM::User::Client;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use BOM::Platform::Event::Emitter;
use Data::Dump 'pp';

# Maximum age of accounts (based on creation date) to not archive
use constant NUMBER_OF_DAYS => 30;

=head1 NAME

derivx_archival_script.pl

=head1 SYNOPSIS

./derivx_archival_script.pl [options] 

=head1 NOTE

This script will archive DerivX accounts based on the following criteria :

 - The accounts have no deals executed for the past 30 days
 - The accounts don't have open positions when the script runs
 - The accounts have less than 5 USD in the balance
 - The account has been created more than a month ago


=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

DerivX account type ('real' or 'demo', default : 'demo')

=item B<-c>, B<--concurrent_calls>

Number of concurrent calls to apply to the script (default : 2)

=item B<-m>, B<--minimum_balance>

Minimum balance required to NOT be archived (default: 5 (USD))

=back

=cut

my $help             = 0;
my $account_type     = 'demo';
my $concurrent_calls = 2;
my $minimum_balance  = 5;

GetOptions(
    'a|account_type=s'     => \$account_type,
    'c|concurrent_calls=i' => \$concurrent_calls,
    'm|minimum_balance=i'  => \$minimum_balance,
    'h|help!'              => \$help,
);

pod2usage(1) if $help;

my @servers = ('demo', 'real');
my ($derivx_accounts, %dxweb_client, %dxsca_client);
my $loop               = IO::Async::Loop->new;
my $derivx_config_file = '/etc/rmg/devexperts.yml';
my $config             = LoadFile($derivx_config_file);
my $user_db            = BOM::Database::UserDB::rose_db();
my $today              = Date::Utility->today();
my $counter            = 0;
my $starting_date      = $today->minus_time_interval(NUMBER_OF_DAYS . 'd')->datetime_iso8601;

for my $server_type (@servers) {
    $loop->add(
        $dxweb_client{$server_type} = WebService::Async::DevExperts::DxWeb::Client->new(
            host    => $config->{servers}{$server_type}{host},
            port    => $config->{servers}{$server_type}{port},
            user    => $config->{servers}{$server_type}{user},
            pass    => $config->{servers}{$server_type}{pass},
            timeout => 15
        ));

    $loop->add(
        $dxsca_client{$server_type} = WebService::Async::DevExperts::Dxsca::Client->new(
            host    => $config->{servers}{$server_type}{host},
            port    => $config->{servers}{$server_type}{port},
            timeout => 15
        ));
}

async sub get_dx_accounts {
    $log->debugf("Fetching %s DerivX accounts from our database...", $account_type);

    my $vrtc_query = "";

    $vrtc_query = " OR loginid LIKE 'VRTC%' " if $account_type eq 'demo';

    try {
        $derivx_accounts = $user_db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    "SET statement_timeout = 0;
                    WITH
                        derivx_accounts AS (
                            SELECT binary_user_id, creation_stamp, loginid, account_type, attributes->>'clearing_code' as clearing_code
                            FROM users.loginid
                            WHERE platform = 'dxtrade'
                            AND account_type = ?
                            AND creation_stamp < NOW() - INTERVAL '" . NUMBER_OF_DAYS . " days'
                            AND status IS NULL
                        ),
                        cr_accounts AS (
                            SELECT DISTINCT ON(binary_user_id) loginid, binary_user_id
                            FROM users.loginid
                            WHERE loginid LIKE 'CR%' $vrtc_query
                            ORDER BY binary_user_id
                        )
                    SELECT cr.loginid AS cr_account,
                        derivx_accounts.binary_user_id AS binary_user_id,
                        derivx_accounts.creation_stamp AS creation_date,
                        derivx_accounts.loginid AS dx_account,
                        derivx_accounts.account_type AS account_type, 
                        derivx_accounts.clearing_code AS clearing_code
                    FROM cr_accounts AS cr
                    JOIN derivx_accounts
                        ON cr.binary_user_id = derivx_accounts.binary_user_id;", {Slice => {}}, $account_type
                );
            });
    } catch ($e) {
        stats_inc("derivx.archival.fetching.failure", {tags => ["error:" . pp($e)]});
        $log->debugf("An error has occured while fetching accounts : %s", pp($e));
        return;
    };

    $log->debugf("Done. Checking fetched %s accounts for archival...", $account_type);

    await fmap_void(
        async sub {
            my $derivx_account = shift;

            try {
                await process_account($derivx_account);
            } catch ($e) {
                # Reset the status in case of any errors so that the account
                # can be picked up in the next run
                $user_db->dbic->run(
                    fixup => sub {
                        $_->do(
                            'SELECT users.update_loginid_status(?,?,?)',
                            undef,
                            $derivx_account->{dx_account},
                            $derivx_account->{binary_user_id}, undef
                        );
                    });

                stats_inc("derivx.archival.processing.failure", {tags => ["account:" . $derivx_account->{dx_account}, "error:" . pp($e)]});
                $log->debugf("An error has occured while processing '%s' : %s. The status of the account will be reset",
                    $derivx_account->{dx_account}, pp($e));
            }
        },
        foreach    => $derivx_accounts,
        concurrent => $concurrent_calls
    );

    $log->debugf("Finished checking fetched accounts for archival");
}

async sub process_account {
    my ($derivx_account) = @_;

    my ($cr_account, $binary_user_id, $creation_date, $dx_account, $type, $clearing_code) =
        @{$derivx_account}{qw/cr_account binary_user_id creation_date dx_account account_type clearing_code/};

    $log->debugf("Checking '%s'..., ", $dx_account);

    my $client = BOM::User::Client->new({loginid => $cr_account});

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $dx = BOM::TradingPlatform->new(
        rule_engine => $rule_engine,
        platform    => 'dxtrade',
        client      => $client
    );

    my ($username, $domain) = split '@', $config->{servers}{$type}{user};
    my $pass = $config->{servers}{$type}{pass};

    $log->debugf("Logging in to DXSCA API");

    await $dxsca_client{$type}->login(
        username => $username,
        domain   => $domain,
        password => $pass,
    );

    $log->debugf("Successfully logged in to DXSCA API");

    return if await check_deals($dx_account, $clearing_code, $type);
    return if await check_balance_and_open_positions($dx, $cr_account, $dx_account, $clearing_code, $type);

    $log->debugf("Will archive '%s'", $dx_account);

    try {
        await $dxweb_client{$type}->account_update(
            clearing_code => $clearing_code,
            account_code  => $dx_account,
            status        => 'TERMINATED'
        );
    } catch ($e) {
        # 404 means account was not found on DerivX,
        # therefore we proceed in archiving it
        $log->debugf("Error when terminating '%s' : %s", $dx_account, pp($e)) unless @$e[2] = '404';
        die $e unless @$e[2] = '404';
    }

    $user_db->dbic->run(
        fixup => sub {
            $_->do('SELECT users.update_loginid_status(?,?,?)', undef, $dx_account, $binary_user_id, 'archived');
        });

    my $active_accounts = get_active_dx_accounts($client->user_id);

    $log->debugf("Done terminating and archiving '%s'", $dx_account);

    unless (scalar(@$active_accounts)) {
        $dx->reset_password($client->user_id);
        stats_inc("derivx.archival.password.reset.success", {tags => ["client:$client->user_id"]});
        $log->debugf("Password for client '%s' has been reset", $client->user_id);
    }

    $log->debugf("Sending email for '%s'", $dx_account);
    # Sending email only for 'real' accounts, not for demo
    BOM::Platform::Event::Emitter::emit(
        'derivx_account_deactivated',
        {
            email      => $client->email,
            first_name => $client->first_name,
            account    => $dx_account,
        },
    ) if ($type eq 'real');

    $log->debugf("Email sent for '%s'", $dx_account);

    $counter++;
    stats_inc("derivx.archival.success", {tags => ["account:$dx_account"]});
    stats_event("DerivX accounts archival", "Processed $counter accounts", {alert_type => 'info'}) unless $counter % 1000;
    $log->debugf("Account '%s' has been successfully archived", $dx_account);
    $log->debugf("----------------");
}

async sub check_deals {
    my ($dx_account, $clearing_code, $type) = @_;

    $log->debugf("Checking deals for '%s'", $dx_account);

    my $client_deals = await $dxsca_client{$type}->order_history(
        accounts       => [$clearing_code . ":" . $dx_account],
        status         => ['COMPLETED'],
        completed_from => $starting_date
    );

    $log->debugf("Found deals for '%s'", $dx_account) if @$client_deals;

    return 1 if @$client_deals;

    $log->debugf("Done checking deals for '%s'", $dx_account);

    return 0;
}

async sub check_balance_and_open_positions {
    my ($dx, $cr_account, $dx_account, $clearing_code, $type) = @_;

    $log->debugf("Checking balance and open positions for '%s'", $dx_account);

    my $client_portfolio = await $dxsca_client{$type}->portfolio(account => $clearing_code . ":" . $dx_account);
    my $account_balance  = 0;
    my $account_currency = 'USD';

    if (scalar @$client_portfolio) {
        if ($client_portfolio->[0]->balances->[0]) {
            $account_balance  = $client_portfolio->[0]->balances->[0]->value;
            $account_currency = $client_portfolio->[0]->balances->[0]->currency;
        }
    } else {
        $log->debugf("Done checking balance and open positions for '%s'", $dx_account);
        return 0;
    }

    my $open_positions = $client_portfolio->[0]->positions;

    if (length($account_balance) or scalar @$open_positions) {
        if ($type eq 'real') {
            $log->debugf("'%s' has a balance bigger than %s or/and open positions\n", $dx_account, $minimum_balance)
                if $minimum_balance <= $account_balance or scalar @$open_positions;
            return 1 if $minimum_balance <= $account_balance or scalar @$open_positions;
            transfer_remaining_funds($dx, $cr_account, $dx_account, $account_balance, $account_currency) if $account_balance > 0;
        } elsif ($type eq 'demo') {
            $log->debugf("'%s' has open positions", $dx_account) if scalar @$open_positions;
            return 1                                             if scalar @$open_positions;
        }
    }

    $log->debugf("Done checking balance and open positions for '%s'", $dx_account);
    return 0;
}

sub transfer_remaining_funds {
    my ($dx, $cr_account, $dx_account, $balance, $currency) = @_;

    $log->debugf("Transfering %s %s  from '%s' to '%s'", $balance, $currency, $dx_account, $cr_account);

    $dx->withdraw(
        amount       => $balance,
        currency     => $currency,
        from_account => $dx_account,
        to_account   => $cr_account
    );

    stats_inc("derivx.archival.transfer.success",
        {tags => ["source_account:$dx_account", "target_account:$cr_account", "amount:$balance $currency"]});
    $log->debugf("Successfully transfered %s %s from '%s' to '%s'", $balance, $currency, $dx_account, $cr_account);
}

=head2 get_active_dx_accounts

Gets active DerivX accounts of clients 

=cut

sub get_active_dx_accounts {
    my ($user_id) = @_;

    my ($result) = $user_db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT loginid FROM users.get_active_dx_accounts(?)", {Slice => {}}, $user_id);
        });

    return $result;
}

await get_dx_accounts();

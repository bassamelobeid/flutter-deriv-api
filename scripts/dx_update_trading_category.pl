use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::Config;
use Getopt::Long;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use Pod::Usage;
use BOM::User::Client;
use BOM::User;
use BOM::Rules::Engine;
use Date::Utility;
use IO::Async::Loop;
use WebService::Async::DevExperts::Dxsca::Client;
use WebService::Async::DevExperts::DxWeb::Client;
use Future::Utils qw( fmap_void try_repeat);
use Future::AsyncAwait;
use YAML::XS                   qw(LoadFile);
use DataDog::DogStatsd::Helper qw(stats_inc);

=head1 NAME

derivx_update_trading_category.pl

=head1 SYNOPSIS

./derivx_update_trading_category.pl [options] 

=head1 NOTE

This script looks for DerivX users with only financial 
or only synthetic accounts and sets the 'market_type' 
attribute in the 'users.loginid' table to 'all'

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-a>, B<--account_type>

MT5 server type ('real' or 'demo')

=item B<-m>, B<--market_type>

Market type ('financial' or 'synthetic')

=item B<-c>, B<--concurrent_calls>

Number of concurrent calls to apply to the script (default : 6)

=item B<-d>, B<--delay_processing>

Delay processing of an account (in seconds)

=back

=cut

my $account_type     = 'demo';
my $market_type      = 'financial';
my $help             = 0;
my $concurrent_calls = 2;
my $delay_processing = 0;

GetOptions(
    'a|account_type=s'     => \$account_type,
    'm|market_type=s'      => \$market_type,
    'c|concurrent_calls=i' => \$concurrent_calls,
    'd|delay_processing=i' => \$delay_processing,
    'h|help!'              => \$help,
);

pod2usage(1) if $help;

my $loop               = IO::Async::Loop->new;
my $derivx_config_file = '/etc/rmg/devexperts.yml';
my $config             = LoadFile($derivx_config_file);
my $user_db            = BOM::Database::UserDB::rose_db();
my $other_market_type  = $market_type eq 'financial' ? 'synthetic' : 'financial';
my $updated_loginids;
my %clients;

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

async sub update_trading_category {
    my ($login) = @_;

    await $clients{$account_type}->account_category_set(
        clearing_code => 'default',
        account_code  => $login,
        category_code => "Trading",
        value         => "CFD",
    );

    $log->infof("%s finished processing account '%s'", Date::Utility->new->db_timestamp, $login);
    stats_inc("derivx.update.trading.category.success", {tags => ["account:" . $login]});
}

async sub get_dx_accounts {
    $log->infof("Fetching %s %s via PSQL...", $account_type, $market_type);

    try {
        $updated_loginids = $user_db->dbic->run(
            fixup => sub {
                my $query = $_->prepare(
                    "SET statement_timeout = 0;
                        SELECT loginid
                        FROM users.loginid
                        WHERE account_type = ?
                        AND status IS NULL
                        AND attributes->> 'market_type' = 'all'
                        AND platform = 'dxtrade';"
                );
                $query->execute($account_type);
                $query->fetchall_arrayref();
            });
    } catch ($e) {
        $log->errorf("An error has occured while fetching %s %s accounts : %s", $account_type, $market_type, $e);
        return;
    };

    $log->infof("Finished fetching %s %s ...", $account_type, $market_type);

    $log->infof("Updating %s %s 'Trading' category...", $account_type, $market_type);

    my $counter     = 0;
    my $epoch_start = Date::Utility->new->epoch;

    await fmap_void(
        async sub {
            my $updated_loginid = shift;

            my $retry = 5;

            await $loop->delay_future(after => $delay_processing);

            try {
                $log->infof("%s processing account %s", Date::Utility->new->db_timestamp, $updated_loginid->[0]);

                my $res = await try_repeat {
                    update_trading_category($updated_loginid->[0]);
                }
                until => sub {
                    my $request = shift;
                    return $request if $request->is_done;
                    $log->infof("Retrying ------");
                    return 1 unless ($retry--);
                    return 0;
                }
            } catch ($e) {
                $log->errorf("An error has occured while processing %s : %s", $updated_loginid->[0], $e);
                stats_inc("derivx.update.trading.category.failure", {tags => ["account:" . $updated_loginid->[0], "error:$e"]});
            }

            $log->info("-------");
            $counter++;

            if ($counter % 100 == 0) {
                my $epoch_end = Date::Utility->new->epoch;
                $log->infof("Processed %s accounts, %s seconds have elapsed", $counter, ($epoch_end - $epoch_start));
            }
        },
        foreach    => $updated_loginids,
        concurrent => $concurrent_calls
    );

    $log->infof("Finished updating %s %s 'Trading' category", $account_type, $market_type);
}

await get_dx_accounts();

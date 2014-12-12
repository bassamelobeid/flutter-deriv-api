#!/usr/bin/perl

BEGIN {
    push @INC, "/home/git/bom/cgi";
}

use strict;
use warnings;
use Getopt::Long;
use BOM::Utility::Log4perl qw( get_logger );
use Path::Tiny;
use BOM::Platform::Email;

use include_common_modules;

use BOM::Utility::Format::Numbers qw(roundnear);
use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet;
use BOM::Platform::Sysinit ();
BOM::Utility::Log4perl::init_log4perl_console;
BOM::Platform::Sysinit::init();

my ($jobs, $currencies, $brokercodes, $for_date);
my $optres = GetOptions(
    'broker-codes=s' => \$brokercodes,
    'currencies=s'   => \$currencies,
    'date=s'         => \$for_date,
);

if (!$optres) {
    print STDERR join(' ', 'Usage:', $0, '[--broker-codes=CR[,MLT[,...]]]', '[--currencies=USD[,GBP[,...]]]', '[--date=2009-12-25]',);
    exit;
}

my $logger = get_logger;

# By default we run all brokers and currencies for today.
$for_date ||= BOM::Utility::Date->new->date_yyyymmdd;

my @brokercodes = ($brokercodes) ? split(/,/, $brokercodes) : BOM::Platform::Runtime->instance->broker_codes->all_codes;
my @currencies  = ($currencies)  ? split(/,/, $currencies)  : BOM::Platform::Runtime->instance->landing_companies->all_currencies;

# This report will now only be run on the MLS.
exit 0 if (BOM::Platform::Runtime->instance->hosts->localhost->canonical_name ne MasterLiveServer());

my $run_for           = BOM::Utility::Date->new($for_date);
my $start_of_next_day = BOM::Utility::Date->new($run_for->epoch - $run_for->seconds_after_midnight)->datetime_iso8601;
my $temp_suffix       = '.temp';

# Now iterate over them in some kind of order.
my $db_write = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
        broker_code => 'FOG',
        operation   => 'write_collector',
    })->db;
my $dbh_write = $db_write->dbh;

# improve speed by commit for batch insert
$dbh_write->{AutoCommit} = 0;

my $balance_sth = $dbh_write->prepare(
    q{
                INSERT INTO accounting.end_of_day_balances (account_id, effective_date, balance)
                    VALUES(?,?,?) RETURNING id
                }
);

my $open_pos_sth = $dbh_write->prepare(
    q{
                INSERT INTO accounting.end_of_day_open_positions
                    (end_of_day_balance_id, financial_market_bet_id, marked_to_market_value)
                    VALUES(?,?,?)
                }
);

my $total_pl;

foreach my $currency (sort @currencies) {
    foreach my $broker (sort @brokercodes) {
        # We don't care about these for Virtuals.
        if ($broker !~ /^\w+$/ or $broker =~ /^VRT/ or $broker eq 'FOG') {
            next;
        }
        $logger->debug('Doing ' . $broker . '-' . $currency . '...');

        my $broker_path = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/f_broker/' . $broker . '/';
        my $ds_path     = $broker_path . 'dailysummary/';

        my $now = BOM::Utility::Date->new;
        local $\ = "\n";
        my $fileext = ($currency eq 'USD') ? "" : '.' . $currency;

        $logger->debug('get_daily_summary_report');

        my $db = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
                broker_code => $broker,
                operation   => 'read_report_binary_replica'
            })->db;

        # Get all of the clients in the DB with this broker code/currency combo, their balance and their agg deposits and withdrawals
        my $client_ref = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
                db => $db,
            }
            )->get_daily_summary_report({
                currency_code     => $currency,
                broker_code       => $broker,
                start_of_next_day => $start_of_next_day,
            });

        $logger->debug('get_accounts_with_open_bets_at_end_of');
        my $accounts_with_open_bet = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
                db => $db,
            }
            )->get_accounts_with_open_bets_at_end_of({
                currency_code     => $currency,
                broker_code       => $broker,
                start_of_next_day => $start_of_next_day,
            });

        # LOOP THROUGH ALL THE CLIENTS
        $logger->debug('...' . scalar(keys(%$client_ref)) . ' clients to do.');
        my @sum_lines;
        my $agg_total_open_bets_profit = 0;

        CLIENT:
        foreach my $login_id (sort keys %{$client_ref}) {
            my $account_id = $client_ref->{$login_id}->{'account_id'};
            my $acbalance  = $client_ref->{$login_id}->{'balance_at'};

            my @eod_id = $dbh_write->selectrow_array($balance_sth, {}, ($account_id, $for_date, $acbalance));

            # Only execute this part if client had open bets at that time.
            my @portfolios;
            my $total_open_bets_value  = 0;
            my $total_open_bets_profit = 0;

            if (exists $accounts_with_open_bet->{$account_id}) {
                my $bets_ref = $accounts_with_open_bet->{$account_id};

                foreach my $bet_id (keys %{$bets_ref}) {
                    my $bet = $bets_ref->{$bet_id};
                    my $theo;

                    eval { $theo = produce_contract($bet->{short_code}, $currency)->theo_price; };
                    if ($@) {
                        $logger->warn(
                            "theo price error[$@], bet_id[" . $bet_id . "], account_id[$account_id], end_of_day_balance_id[" . $eod_id[0] . "]");
                        next;
                    }

                    $open_pos_sth->execute(($eod_id[0], $bet_id, $theo));

                    my $portfolio = "1L $bet->{buy_price} $bet->{short_code} ($theo)";
                    push @portfolios, $portfolio;

                    $total_open_bets_value  += $theo;
                    $total_open_bets_profit += ($theo - $bet->{buy_price});
                }
            }

            # open positions value minus buy prices
            $total_open_bets_profit = roundnear(0.01, $total_open_bets_profit);
            $agg_total_open_bets_profit += $total_open_bets_profit;

            # Withdrawals are stored as negative numbers, so we just add here.
            my $agg_deposit_withdrawal = roundnear(0.01, $client_ref->{$login_id}->{'deposits'} + $client_ref->{$login_id}->{'withdrawals'});
            my $total_equity           = roundnear(0.01, $total_open_bets_value + $acbalance);
            $acbalance = roundnear(0.01, $acbalance);

            my $summary_line =
                join(',', ($login_id, $acbalance, $total_open_bets_value, $total_open_bets_profit, $total_equity, $agg_deposit_withdrawal));
            $summary_line .= ',' . join('+', @portfolios) if scalar @portfolios;
            push @sum_lines, $summary_line . "\n";
        }

        if (scalar keys %{$client_ref} > 0) {
            $dbh_write->commit;
        }

        Path::Tiny::path($ds_path)->mkpath if (not -d $ds_path);

        my $summary     = $ds_path . $run_for->date_ddmmmyy . '.summary' . $fileext;
        my $tempsummary = $summary . $temp_suffix;
        my $sm_fh       = new IO::File '> ' . $tempsummary || die '[' . $0 . '] Can\'t write to ' . $tempsummary . ' ' . $!;

        my $generation_msg =
              '\#File generated for '
            . $run_for->date . ' on '
            . $now->datetime
            . ' from entire database since inception by f_consolidated.cgi ('
            . $currency . ")\n";

        my $header = "loginid,account_balance,total_open_bets_value,total_open_bets_profit,total_equity,aggregate_deposit_withdrawals,portfolio\n";
        print $sm_fh ($generation_msg, $header, @sum_lines);
        close $sm_fh;
        rename($tempsummary, $summary);

        $total_pl->{$broker}->{$currency} = $agg_total_open_bets_profit;
    }
}

my @mail_msg;
foreach my $broker (keys %{$total_pl}) {
    foreach my $currency (keys %{$total_pl->{$broker}}) {
        push @mail_msg, "$broker, $currency, $total_pl->{$broker}->{$currency}";
    }
}
send_email({
    'from'    => 'system@binary.com',
    'to'      => BOM::Platform::Runtime->instance->app_config->accounting->email,
    'subject' => 'Daily Outstanding Bets Profit / Lost [' . $run_for->date . ']',
    'message' => \@mail_msg,
});

$logger->debug('Finished.');

1;

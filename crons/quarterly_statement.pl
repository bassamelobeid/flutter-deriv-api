#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Getopt::Long qw(GetOptions);
Getopt::Long::Configure qw(gnu_getopt);

use POSIX;
use Template;
use Try::Tiny;
use Path::Tiny;
use Date::Utility;
use Email::Stuffer;
use JSON::MaybeXS;

use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Platform::Context qw(localize);

use Finance::Asset::Market::Registry;
use Finance::Contract::Longcode qw( shortcode_to_longcode shortcode_to_parameters );
use Format::Util::Numbers qw/formatnumber roundcommon/;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'debug';

my $send_emails  = 0;
my $show_summary = 0;
my $show_clients = 0;

# parse command line options
GetOptions(
    'send-emails|s'   => \$send_emails,
    'print-summary|i' => \$show_summary,
    'print-clients|c' => \$show_clients,
) or die 'Usage $0 [--send-emails] [--print-summary] [--print-clients] <quarter>';

# Decide which quarter we're running for, and the start/end dates
my $quarter = shift(@ARGV) || do {
    my $date = Date::Utility->new->_minus_months(1);
    $date->year . 'Q' . $date->quarter_of_year;
};
die 'invalid quarter format - expected something like 2017Q3' unless $quarter =~ /^\d{4}Q[1-4]$/;

my $months_in_quarter = 3;
my $start             = Date::Utility->new($quarter =~ s{Q([1-4])}{'-' . (1 + $months_in_quarter * ($1 - 1)) . '-01'}er);
my $end               = $start->plus_time_interval($months_in_quarter . 'mo');

$log->infof('Generating client quarterly statement emails for %s (%s - %s)', $quarter, $start->iso8601, $end->iso8601);

my $tt = Template->new(ABSOLUTE => 1);

# This is hardcoded to work on European clients only, since it's required for regulatory reasons there.
my @brokers = qw/MF/;
for my $broker (@brokers) {
    my @client_list = ();
    # Iterate through all clients - we have few enough that we can pull the entire list into memory
    # (even if we increase userbase by 100x or more). We don't filter out by status at this point:
    # the statement generation may take a few seconds for each client, and there's a chance
    # that the status will change during the run.
    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbic;

    my $clients = $dbic->run(
        fixup => sub {
            $_->selectcol_arrayref(q{SELECT loginid FROM betonmarkets.client});
        });

    $log->infof('Found a total of %d clients in %s', 0 + @$clients, $broker);

    for my $loginid (@$clients) {
        try {

            $log->infof('Instantiating %s', $loginid);
            my $start_time = Time::HiRes::time;

            my $client = BOM::User::Client->new({
                loginid      => $loginid,
                db_operation => 'replica'
            });

            # Skip any inactive clients
            return $log->infof('Skipping %s due to unwelcome status', $loginid) if $client->status->get('unwelcome');
            return $log->infof('Skipping %s due to disabled status',  $loginid) if $client->status->get('disabled');

            my $summary = $client->db->dbic->run(
                fixup => sub {
                    $_->selectall_hashref('select * from quarterly_statement_summary(?, ?, ?)',
                        'account_id', {}, $start->iso8601, $end->iso8601, $loginid);
                });

            # Get the summary information for the loginId
            my $result = (values %$summary)[0];

            my $txn_dm = BOM::Database::DataMapper::Transaction->new({
                client_loginid => $loginid,
                currency_code  => $client->currency,
                db             => $client->db,
            });

            my $trades = $txn_dm->get_transactions({
                before => $end->iso8601,
                after  => $start->iso8601,
                limit  => 0
            });

            my ($payments, $open_trades, $closed_trades);
            # filter closed trades and payment
            foreach (@$trades) {
                if (defined $_->{payment_id}) {
                    push @$payments, $_;
                } elsif ($_->{amount} != 0 && $_->{is_sold}) {
                    $_->{long_code} = localize(shortcode_to_longcode($_->{short_code}, $client->currency));
                    push @$closed_trades, $_;
                }
            }

            my $open_bets = $client->db->dbic->run(
                fixup => sub {
                    $_->selectall_arrayref(
                        'select * from bet.get_open_bets_of_account(?,?,?)',
                        {Slice => {}},
                        $client->loginid, $client->currency, 'false'
                    );
                });

            my $estimated_profit = 0;
            foreach (@$open_bets) {
                my $open_trade = decode_json($_->{result});

                $open_trade->{purchase_time} = Date::Utility->new($open_trade->{purchase_time});
                $open_trade->{expiry_time}   = Date::Utility->new($open_trade->{expiry_time});
                $open_trade->{start_time}    = Date::Utility->new($open_trade->{start_time});
                $open_trade->{long_code}     = localize(shortcode_to_longcode($open_trade->{short_code}, $client->currency));

                my $remaining_time = $open_trade->{expiry_time}->days_between(Date::Utility->new());

                if ($remaining_time == 0) {
                    $remaining_time = floor(($open_trade->{expiry_time}->epoch - Date::Utility->new->epoch) / 3600) . ' Hours';
                } else {
                    $remaining_time = $remaining_time . ' Days';
                }

                my $contract = produce_contract($open_trade->{short_code}, $client->currency);
                if (defined $open_trade->{buy_price} and (defined $contract->bid_price or defined $contract->{sell_price})) {
                    $open_trade->{profit} = _get_profit($contract, $open_trade->{buy_price}, $client->currency);
                }

                $estimated_profit += $open_trade->{profit};
                $open_trade->{remaining_time}   = $remaining_time;
                $open_trade->{indicative_price} = $open_trade->{buy_price} + $open_trade->{profit};
                push @$open_trades, $open_trade;
            }

            my $data = {
                client => {
                    %$result,
                    estimated_value => $result->{ending_balance} + $estimated_profit,
                    closed_trades   => $closed_trades,
                    open_trades     => $open_trades,
                    payments        => $payments,
                    name            => $client->first_name . ' ' . $client->last_name,
                    account_number  => $client->loginid,
                    classification  => $client->status->get('professional') ? 'Professional' : 'Retail',
                    currency        => $client->currency,
                },
                date      => Date::Utility->new->date_yyyymmdd,
                statement => {
                    start_date => $start->date_ddmmmyyyy,
                    end_date   => $end->minus_time_interval('1d')->date_ddmmmyyyy,
                }};

            $tt->process('/home/git/regentmarkets/bom-backoffice/templates/email/quarterly_statement.html.tt', $data, \my $html)
                or die 'Template error: ' . $tt->error;

            if ($send_emails) {
                Email::Stuffer->from('support@binary.com')->to($client->email)->subject("Quarterly Statement")->html_body($html)->send_or_die;
            }

            $log->infof("Statement proccessed for client: %s and email sent for: %s", $loginid, $client->email) if $show_clients;

            my $elapsed = Time::HiRes::time - $start_time;
            $log->infof(
                "Statement summary for client: %s: starting balance: %d, deposits: %d, withdrawals: %d, total buy price: %d, total fees: %d, ending balance: %d, estimated value: %d in %.2f seconds\n",
                $loginid,                  $result->{starting_balance},        $result->{deposits},
                $result->{withdrawals},    $result->{total_buy_price},         $result->{total_fees},
                $result->{ending_balance}, $data->{client}->{estimated_value}, $elapsed
            ) if $show_summary;
            push @client_list,
                {
                %$result,
                elapsed => $elapsed,
                loginid => $loginid
                };

        }
        catch {
            $log->errorf('Failed to process quarterly statement for client [%s] - %s', $loginid, $_);
        }
    }

    {
        $tt->process(
            '/home/git/regentmarkets/bom-backoffice/templates/email/quarterly_statement_summary.html.tt',
            {client_list => \@client_list},
            \my $summary
        ) or die 'Template error: ' . $tt->error;

        Email::Stuffer->from('support@binary.com')->to('compliance@binary.com')->subject("Quarterly Statement summary - $broker")
            ->html_body($summary)->send_or_die;
    }
}

sub _get_profit {
    my ($contract, $buy_price, $currency) = @_;
    return (defined $contract->{sell_price})
        ? formatnumber('price', $currency, $contract->{sell_price} - $buy_price)
        : formatnumber('price', $currency, $contract->{bid_price} - $buy_price);
}

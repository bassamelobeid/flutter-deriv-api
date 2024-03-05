#!/usr/bin/perl
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Transaction;
use Log::Any qw($log);
use Getopt::Long;
use Syntax::Keyword::Try;

require Log::Any::Adapter;

my $now = Date::Utility->new()->datetime;
GetOptions("d|date=s" => \(my $date = $now));

Log::Any::Adapter->import(
    qw(DERIV),
    stderr => 'json',
    stdout => 'text',
);

$log->info('Starting sell_expired_unsold_contracts cron to sell unsold expired demo contracts.');

my $vr = BOM::Database::ClientDB->new({broker_code => 'VRTC'});
# source 3 is app id for riskd
my $source = 3;

my $all_expired_unsold = $vr->db->dbic->run(
    fixup => sub {
        $_->selectall_arrayref(
            q{SELECT DISTINCT acc.client_loginid
                FROM bet.financial_market_bet_open fmbo
                    JOIN transaction.account acc ON fmbo.account_id=acc.id
                WHERE purchase_time < ?::timestamp - interval '30 days';},
            {}, $date
        );
    });

# sell expired but unsold contracts
foreach my $data (@$all_expired_unsold) {
    my ($loginid) = @$data;
    try {
        BOM::Transaction::sell_expired_contracts({
            client => BOM::User::Client->new({loginid => $loginid}),
            source => $source,
        });
    } catch {
        $log->warn("failed to sell all expired contracts for $loginid. Skipping ...");
    };
}

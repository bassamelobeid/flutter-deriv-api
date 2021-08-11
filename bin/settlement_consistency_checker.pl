#!/usr/bin/env perl 
use strict;
use warnings;

use Syntax::Keyword::Try;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw(produce_contract);
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use Format::Util::Numbers;
use List::Util qw(min max);

use Log::Any qw($log);
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => 'info';

++$|;
my $broker_code = 'CR';
my $clientdb    = BOM::Database::ClientDB->new({
    broker_code => $broker_code,
    operation   => 'replica'
});

my $dbh     = $clientdb->db->dbh;
my $last_id = 0;
my $count   = 0;

my $precision_config = Format::Util::Numbers::get_precision_config()->{price};

$log->info("Starting price consistency checker ...");

while (1) {

    #Based on DataDog statistics, buy attemp is around 8 per sec and
    #at peak time around 15 per second. With 20 per sec, we should have
    #enough buffer. Therefore we use 300 for limit in the sql.
    for my $row (
        $dbh->selectall_arrayref(
            q{
            SELECT f.id, f.short_code, f.is_expired, f.is_sold,
                   f.expiry_time, f.sell_price, a.currency_code
             FROM bet.financial_market_bet f JOIN transaction.account a ON a.id = f.account_id
             WHERE (f.is_expired) AND (f.bet_class <> 'multiplier')
               AND ($1 is null or f.id > $1)
             ORDER BY f.id desc
             LIMIT 300
             },
            {Slice => {}},
            $last_id
        )->@*
        )
    {
        $last_id = max($row->{id}, $last_id);

        my $sell_price = 0 + $row->{sell_price};

        try {
            my $c         = produce_contract($row->{short_code}, $row->{currency_code});
            my $precision = $precision_config->{$row->{currency_code}} // 0;

            if ($c->is_expired and abs($c->value - $sell_price) > $precision) {
                my $error_msg = sprintf "FMB ID %s has expected sell price %s and value %s\n", $row->{id}, $sell_price, $c->value;

                stats_event("Inconsistent settlement price", $error_msg, {alert_type => 'error'});
            }
        } catch {
            $log->info("Exception $@ for ID $row->{id} on $row->{expiry_time} with $row->{short_code}");
        }
    }
    sleep 15;
}

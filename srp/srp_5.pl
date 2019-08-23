use strict;
use warnings;

use Date::Utility;

use ExchangeRates::CurrencyConverter qw(convert_currency);
use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use BOM::User::Client;
use BOM::Platform::Event::Emitter;
use BOM::Config;

my $db = BOM::Database::ClientDB->new({broker_code => 'MX'})->db->dbic;
my $redis = BOM::Config::RedisReplicated::redis_events();

# Conditions for the SQL:
# - Transactions in the last 30 days
# - Done by client only
# - Done through doughflow (deposits and withdrawals)

my $previous_30days_arrayref = $db->run(
    fixup => sub {
        $_->selectall_arrayref("
            SELECT ta.client_loginid, pp.payment_time, pp.amount, ta.currency_code
            FROM payment.payment AS pp
            INNER JOIN transaction.account AS ta ON ta.id = pp.account_id
            WHERE pp.payment_time::date >= now()::date - 30
            AND pp.staff_loginid = ta.client_loginid
            AND pp.payment_gateway_code = 'doughflow'
            ORDER BY pp.payment_time ASC
        ", { Slice => {} });
    }
);

my $new_storage_hashref;

# Loop through one row at a time
foreach my $transaction (@$previous_30days_arrayref) {

    my $amount = $transaction->{amount};
    my $loginid = $transaction->{client_loginid};
    my $payment_time = $transaction->{payment_time};
    
    # Check if positive (deposit) or negative (withdrawal)
    if($amount < 0) {
        $new_storage_hashref->{$loginid}->{earliest_withdrawal_time} //= $payment_time;
        $new_storage_hashref->{$loginid}->{withdrawal} += abs($amount);
    } else {
        $new_storage_hashref->{$loginid}->{earliest_deposit_time} //= $payment_time;
        $new_storage_hashref->{$loginid}->{deposit} += abs($amount);
    }
    
    $new_storage_hashref->{$loginid}->{currency} = $transaction->{currency_code};
    
}

# hardcoding iom, as it only queries MX here
my $payment_check_limits = BOM::Config::payment_limits()->{qualifying_payment_check_limits}->{'iom'};

my $limit_val = $payment_check_limits->{limit_for_days};
my $limit_cur = $payment_check_limits->{currency};
my $duration_days = $payment_check_limits->{for_days} + 1; # Use one extra day as a buffer

# Loop through the hashref
foreach my $loginid (keys %$new_storage_hashref) {
    
    my $record = $new_storage_hashref->{$loginid};
    my $currency = $record->{currency};
    my $key;
    
    my $deposit_total = $record->{deposit} // 0;
    my $withdrawal_total = $record->{withdrawal} // 0;
    
    # Store the deposits and withdrawals in redis
    if($deposit_total > 0) {
        $key = $loginid . '_deposit_qualifying_payment_check';
        
        my $earliest_deposit_date = Date::Utility->new($record->{earliest_deposit_time});
        my $days_gap = Date::Utility::today()->days_between($earliest_deposit_date);
        
        $redis->set(
            $key => $deposit_total,
            EX   => 86400 * ($duration_days - $days_gap) # Use one extra day as a buffer
        );
    }
    
    if ($withdrawal_total > 0) {
        $key = $loginid . '_withdrawal_qualifying_payment_check';
        
        my $earliest_withdrawal_date = Date::Utility->new($record->{earliest_withdrawal_date});
        my $days_gap = Date::Utility::today()->days_between($earliest_withdrawal_date);
        
        $redis->set(
            $key => $withdrawal_total,
            EX   => 86400 * ($duration_days - $days_gap) # Use one extra day as a buffer
        );
    }
    
    # If either the deposit or withdrawal is greater than the threshold, send an event request
    my $threshold_val = convert_currency($limit_val, $limit_cur, $currency);
    
    if($deposit_total >= $threshold_val || $withdrawal_total >= $threshold_val) {
        my $event_name = $loginid . '_qualifying_payment_check';
        BOM::Platform::Event::Emitter::emit('qualifying_payment_check', {loginid => $loginid}) if $redis->setnx($event_name, 1);
    }
}


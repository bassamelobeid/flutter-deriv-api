#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use JSON;
use Data::Dumper;
use Date::Utility;
use DateTime;

use f_brokerincludeall;
use BOM::Platform::Context;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::View::Controller::Bet;

BOM::Platform::Sysinit::init();
PrintContentType();
BrokerPresentation("SHOW CLIENT COMBINED TRACE");

my $loginid    = uc(request()->param('loginid'));
my $startdate  = request()->param('startdate');
my $enddate    = request()->param('enddate');

# get client complete transaction statements
my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid});
if (not $client) {
    print "Error : wrong loginID ($loginid) could not get client instance";
    code_exit_BO();
}

my @audit_entries;
my %wd_query = (
    login_date => {ge_le => [DateTime->from_epoch(epoch => Date::Utility->new({datetime => $startdate})->epoch), DateTime->from_epoch(epoch => Date::Utility->new({datetime => $enddate})->epoch)]},
);

my $logins = $client->find_login_history(
    query   => [%wd_query],
    sort_by => 'login_date',
    limit   => 200,
);

foreach my $login (@$logins) {
    my $date        = $login->login_date->strftime('%F %T');
    my $status      = $login->login_successful ? 'ok' : 'failed';
    push @audit_entries, {timestring => $date, description => $date . " logged in: " . $status . " " . $login->login_environment , color => 'green' };
}

my $currency = $client->currency;

my $statement = client_statement_for_backoffice({
    client   => $client,
    before   => Date::Utility->new({datetime => $enddate})->plus_time_interval('1d')->date,
    after    => $startdate,
    currency => $currency,
});

foreach my $transaction (@{$statement->{transactions}}) {
    if (defined $transaction->{financial_market_bet_id}) {
        my $key = $transaction->{date}->datetime;
        my $info = BOM::View::Controller::Bet::get_info($transaction, $currency);
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id} . " description: " . $info->{longcode};
        $key_value .= " buy_price: " . $transaction->{buy_price} if $transaction->{buy_price};
        $key_value .= " sell_price: " . $transaction->{sell_price} if $transaction->{sell_price};
        push @audit_entries, { timestring => $key, description => $key_value, color => 'gray' };
    } else {
        my $key = $transaction->{date}->datetime;
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id} . " description: " . $transaction->{payment_remark} . " amount: $currency " . $transaction->{amount};
        push @audit_entries, { timestring => $key, description => $key_value, color => 'red' };
    }
}


my $dbh = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
        operation   => 'backoffice_replica',
    })->db->dbh or die "[$0] cannot create connection";
$dbh->{AutoCommit} = 0;
$dbh->{RaiseError} = 1;

my $u_db;
my $prefix;
foreach my $table (qw(client client_status client_promo_code client_authentication_method client_authentication_document login_history self_exclusion) ) {
    $prefix = ($table eq 'client')? '':'client_';
    $u_db = $dbh->selectall_hashref("SELECT * FROM audit.$table WHERE ".$prefix."loginid='$loginid' and stamp between '$startdate'::TIMESTAMP and '$enddate'::TIMESTAMP order by stamp", 'stamp');

    my $old;
    foreach my $stamp (sort keys %{$u_db}) {
        my $new = $u_db->{$stamp};
        my $diffs;
        foreach my $key (sort keys %{$u_db->{$stamp}}) {
            $new->{secret_answer} = BOM::Platform::Client::Utility::decrypt_secret_answer($new->{secret_answer}) if $key eq 'secret_answer';
            if ($key eq 'client_addr') {
                my $ip = $new->{client_addr};
                $ip =~ s/\/32//g;
                my $reverse = `/usr/bin/host $ip`;
                $reverse =~ /\s([^\s]+)\.$/;
                if ($1) {
                    $new->{client_addr} = $1;
                }
            }
            $new->{$key} = '' if not $new->{$key};
            if ($key !~ /(stamp|operation|pg_userid|client_addr|client_port|id)/) {
                if ($old and $old->{$key} ne $new->{$key}) {
                    $diffs->{$key} = 1;
                }
            }
            
        }
        if ($diffs) {

            my $desc=$u_db->{$stamp}->{stamp} . " $table " . join(' ', map {$u_db->{$stamp}->{$_}} qw(operation pg_userid client_addr client_port)).'<ul>';

            foreach my $key (keys %{$diffs}) {
                $desc .= "<li> $key ". ' ' . 'change from <b>'. $old->{$key} . '</b> to <b>' . $new->{$key} . '</b> </li> ';
            }
            push @audit_entries, { timestring => $stamp, description =>  "$desc</ul>", color => 'blue' };
        }
        $old = $new;

    }
}


print "<table style='background-color:white'>";
foreach (sort { Date::Utility->new($a->{timestring})->epoch <=> Date::Utility->new($b->{timestring})->epoch } @audit_entries ) {
    print "<tr><td><div style='color:".$_->{color}."'>" . $_->{description} . "</div></td></tr>";
}
print "</table>";

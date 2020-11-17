#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

no indirect;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use Date::Utility;
use Syntax::Keyword::Try;
use HTML::Entities;
use URI;
use Mojo::UserAgent;

use f_brokerincludeall;
use BOM::User::Utility;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Config;
use BOM::User::Client;
use feature "state";

BOM::Backoffice::Sysinit::init();
PrintContentType();

my $loginid         = uc(request()->param('loginid'));
my $startdate       = request()->param('startdate');
my $enddate         = request()->param('enddate');
my $encoded_loginid = encode_entities($loginid);

# get client complete transaction statements
my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid, db_operation => 'backoffice_replica'}) };
if (not $client) {
    code_exit_BO("Error : wrong loginID ($encoded_loginid) could not get client instance");
}

try {
    $startdate = Date::Utility->new($startdate)->date;
    $enddate   = Date::Utility->new($enddate)->date;
} catch {
    code_exit_BO("Cannot parse dates: $startdate or $enddate: $@");
}

my $currency = $client->currency;

my $transactions = get_transactions_details({
    client   => $client,
    from     => $startdate,
    to       => Date::Utility->new({datetime => $enddate})->plus_time_interval('1d')->date,
    currency => $currency,
    limit    => 10000,
});

my @audit_entries;
foreach my $transaction (@{$transactions}) {
    if (defined $transaction->{financial_market_bet_id}) {
        my $key       = $transaction->{date}->datetime;
        my $key_value = $key . " staff: " . $transaction->{staff_loginid} . " ref: " . $transaction->{id};
        $key_value .= " buy_price: " . $transaction->{buy_price}   if $transaction->{buy_price};
        $key_value .= " sell_price: " . $transaction->{sell_price} if $transaction->{sell_price};
        push @audit_entries,
            {
            timestring  => $key,
            description => $key_value,
            color       => 'gray'
            };
    } else {
        my $key = $transaction->{date}->datetime;
        my $key_value =
              $key
            . " staff: "
            . $transaction->{staff_loginid}
            . " ref: "
            . $transaction->{id}
            . " description: "
            . $transaction->{payment_remark}
            . " amount: $currency "
            . $transaction->{absolute_amount};
        push @audit_entries,
            {
            timestring  => $key,
            description => $key_value,
            color       => 'red'
            };
    }
}

my $dbic = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
        operation      => 'backoffice_replica',
    }
    )->db->dbic
    or die "[$0] cannot create connection";

foreach my $table (
    qw(client client_status client_promo_code client_authentication_method client_authentication_document self_exclusion financial_assessment))
{
    my $column_name = ($table eq 'client') ? 'loginid' : 'client_loginid';
    my $u_db        = $dbic->run(
        fixup => sub {
            $_->selectall_hashref("SELECT * from audit.get_client_audit_details(?::TEXT,?::TEXT,?::VARCHAR,?::DATE,?::DATE)",
                'data', {}, $table, $column_name, $loginid, $startdate, $enddate);
        });
    my %u_db_hash;
    # convert JSON to respective records.
    foreach my $data (keys %{$u_db}) {
        my $record = decode_json($data);
        $u_db_hash{$record->{stamp}} = $record;
    }
    my $old;
    foreach my $stamp (sort keys %u_db_hash) {
        my $new = $u_db_hash{$stamp};
        my $diffs;
        if (not $old) {
            $old = $new;
        }
        if ($new->{operation} eq 'INSERT' or $new->{operation} eq 'DELETE') {
            my $desc = $new->{stamp} . " [$table audit table] " . join(' ', map { $new->{$_} } qw(operation client_addr)) . '<ul>';
            foreach my $key (keys %{$new}) {
                $desc .= "<li> $key is <b>" . ($new->{$key} || '') . '</b> </li> ';
            }
            push @audit_entries,
                {
                timestring  => $new->{stamp},
                description => "$desc</ul>",
                color       => 'purple'
                };
            $old = $new;
        }
        foreach my $key (sort keys %{$u_db_hash{$stamp}}) {
            if ($key eq 'secret_answer') {
                try {
                    $new->{secret_answer} = BOM::User::Utility::decrypt_secret_answer($new->{secret_answer});
                } catch {
                    $new->{secret_answer} = 'Unable to extract secret answer. Client secret answer is outdated or invalid.';
                }
            }
            if ($key eq 'client_addr') {
                $old->{client_addr} = revers_ip($old->{client_addr});
            }
            $new->{$key} = '' if not $new->{$key};
            if ($key !~ /(stamp|operation|pg_userid|client_addr|client_port)/) {
                if ($old and $old->{$key} ne $new->{$key}) {
                    $diffs->{$key} = 1;
                }
            }
        }
        if ($diffs) {

            my $desc = $old->{stamp} . " [$table audit table] " . join(' ', map { $old->{$_} } qw(operation client_addr)) . '<ul>';

            foreach my $key (keys %{$diffs}) {
                $desc .= "<li> $key " . ' ' . 'change from <b>' . $old->{$key} . '</b> to <b>' . $new->{$key} . '</b> </li> ';
            }
            push @audit_entries,
                {
                timestring  => $old->{stamp},
                description => "$desc</ul>",
                color       => 'blue'
                };
        }
        $old = $new;

    }
}

print "<div style='background-color:yellow'>$encoded_loginid</div>";
print "<div style='background-color:white'>";
my $old;
foreach (sort { Date::Utility->new($a->{timestring})->epoch <=> Date::Utility->new($b->{timestring})->epoch } @audit_entries) {
    print '<hr>' if (substr($_->{timestring}, 0, 10) ne substr($old->{timestring}, 0, 10));
    print "<div style='font-size:11px;color:" . $_->{color} . "'>" . $_->{description} . "</div>";
    $old = $_;
}
print "</div>";

sub revers_ip {
    my $client_ip = shift;
    state $r;
    if ($r->{$client_ip}) {
        return $r->{$client_ip};
    }
    my $ip = $client_ip;
    $ip =~ s/\/32//g;
    my $reverse = `/usr/bin/host $ip`;
    $reverse =~ /\s([^\s]+)\.$/;
    if ($1) {
        $r->{$client_ip} = $1;
    } else {
        $r->{$client_ip} = $ip;
    }
    return $r->{$client_ip};
}

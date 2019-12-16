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
use Try::Tiny;
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
my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginid,
    db_operation => 'replica'
});
if (not $client) {
    code_exit_BO("Error : wrong loginID ($encoded_loginid) could not get client instance");
}

try {
    $startdate = Date::Utility->new($startdate)->date;
    $enddate   = Date::Utility->new($enddate)->date;
}
catch {
    code_exit_BO("Cannot parse dates: $startdate or $enddate: $_");
};

my $currency = $client->currency;

my $statement = client_statement_for_backoffice({
    client              => $client,
    before              => Date::Utility->new({datetime => $enddate})->plus_time_interval('1d')->date,
    after               => $startdate,
    currency            => $currency,
    max_number_of_lines => 10000,
});

my @audit_entries;
foreach my $transaction (@{$statement->{transactions}}) {
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
            . $transaction->{amount};
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

my $u_db;
my $prefix;
foreach my $table (
    qw(client client_status client_promo_code client_authentication_method client_authentication_document self_exclusion financial_assessment))
{
    $prefix = ($table eq 'client') ? '' : 'client_';
    $u_db = $dbic->run(
        fixup => sub {
            $_->selectall_hashref(
                "SELECT * FROM audit.$table WHERE "
                    . $prefix
                    . "loginid='$loginid' and stamp between '$startdate'::TIMESTAMP and '$enddate'::TIMESTAMP order by stamp",
                'stamp'
            );
        });

    my $old;
    foreach my $stamp (sort keys %{$u_db}) {
        my $new = $u_db->{$stamp};
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
        foreach my $key (sort keys %{$u_db->{$stamp}}) {
            if ($key eq 'secret_answer') {
                try {
                    $new->{secret_answer} = BOM::User::Utility::decrypt_secret_answer($new->{secret_answer});
                }
                catch {
                    $new->{secret_answer} = 'Unable to extract secret answer. Client secret answer is outdated or invalid.';
                };
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

#add desk.com entries
push @audit_entries, _get_desk_com_entries($loginid, $startdate, $enddate);
push @audit_entries, _get_desk_com_entries($loginid, $startdate, $enddate, 'deleted');

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

sub _get_desk_created_string {
    my $start_date = shift;
    my $end_date   = shift;

    $start_date = Date::Utility->new($start_date);
    $end_date   = Date::Utility->new($end_date);

    my $created      = 'today';
    my $days_between = $end_date->days_between($start_date);
    if ($days_between < 1) {
        $created = 'today';
    } elsif ($days_between >= 1 and $days_between <= 7) {
        $created = 'week';
    } elsif ($days_between <= 31) {
        $created = 'month';
    } else {
        $created = 'year';
    }
    return $created;
}

sub _get_desk_com_entries {
    my $loginid   = shift;
    my $startdate = shift;
    my $enddate   = shift;
    my $status    = shift;

    my $color = $status ? 'red' : 'black';

    my @desk_entries;
    my $ua = Mojo::UserAgent->new;
    try {
        my $uri = URI->new(BOM::Config::third_party()->{desk}->{api_uri} . 'cases/search');
        $uri->query_param(
            q => 'custom_loginid:' . $loginid . ' created:' . _get_desk_created_string($startdate, $enddate) . ($status ? '+status:' . $status : ''));
        $uri->query_param(sort_field     => 'created_at');
        $uri->query_param(sort_direction => 'asc');
        $uri->userinfo(BOM::Config::third_party()->{desk}->{username} . ":" . BOM::Config::third_party()->{desk}->{password});
        my $res = $ua->get(
            "$uri",
            => {
                Accept => 'application/json',
            });
        die $res->message if $res->is_error;
        die 'unknown issue with request' unless $res->is_success;
        my $response = decode_json_utf8($res->body);

        if ($response->{total_entries} > 0 and $response->{_embedded} and $response->{_embedded}->{entries}) {
            foreach (sort { Date::Utility->new($a->{created_at})->epoch <=> Date::Utility->new($b->{created_at})->epoch }
                @{$response->{_embedded}->{entries}})
            {
                my $stamp = Date::Utility->new($_->{created_at})->datetime;
                my $case =
                      $stamp
                    . ' <strong>Desk.com Id</strong>: '
                    . $_->{id}
                    . ' <strong>description</strong>: '
                    . $_->{blurb}
                    . ' <strong>status</strong>: '
                    . $_->{status};
                $case .= ' <strong>updated at</strong>: ' . Date::Utility->new($_->{updated_at})->datetime   if $_->{updated_at};
                $case .= ' <strong>resolved at</strong>: ' . Date::Utility->new($_->{resolved_at})->datetime if $_->{resolved_at};
                $case .= ' <strong>type</strong>: ' . $_->{type}                                             if $_->{type};
                $case .= ' <strong>subject</strong>: ' . $_->{subject}                                       if $_->{subject};

                push @desk_entries,
                    {
                    timestring  => $stamp,
                    description => $case,
                    color       => $color
                    };
            }
        } else {
            push @desk_entries,
                {
                timestring  => Date::Utility::today()->datetime,
                description => Date::Utility::today()->datetime . ' No desk.com record found',
                color       => $color
                };
        }
    }
    catch {
        push @desk_entries,
            {
            timestring  => Date::Utility::today()->datetime,
            description => Date::Utility::today()->datetime . ' Error occurred while accessing desk.com',
            color       => $color
            };
    };

    return @desk_entries;
}

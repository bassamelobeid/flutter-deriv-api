#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use POSIX;
use Date::Utility;
use Path::Tiny;
use Brands;
use Client::Account;
use HTML::Entities;
use Format::Util::Numbers qw/roundcommon/;

use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use BOM::Database::DataMapper::Account;
use BOM::Backoffice::Request qw(request);
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use open qw[ :encoding(UTF-8) ];
use BOM::Backoffice::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $show = encode_entities(request()->param('show') // "");
if (request()->param('action') ne 'DOWNLOAD CSV') {
    PrintContentType();
    BrokerPresentation("MONITOR $show");
}

my $broker = encode_entities(request()->broker_code // "");
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $home_link = request()->url_for('backoffice/f_viewclientsubset.cgi');

# This block of code shall come before PrintContentType, as PrintContentType will overwrite our
# intention of outputing CSV file.
if (request()->param('action') eq 'DOWNLOAD CSV') {
    PrintContentType_excel($broker . '-client.csv');

    my $csv = Text::CSV->new({
            binary       => 1,
            always_quote => 1,
            quote_char   => "'",
            eol          => "\n"
        })    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();

    my @header = (
        'LOGINID', 'NAME', 'COUNTRY', 'EMAIL', 'AGG. DEPOSITS - WITHDRAWALS',
        'CASH BALANCE', 'CASHIER',
        'TOTAL EQUITY & Expired contracts',
        'Last access (in days)', 'reason'
    );
    $csv->combine(@header);
    print $csv->string;

    my $results = get_client_by_status({
        'broker' => $broker,
        'show'   => $show,
    });
    foreach my $loginid (keys %{$results}) {
        my $client = $results->{$loginid};
        my @row    = (
            $loginid,                         $client->{name},              $client->{citizen},        $client->{email},
            '$' . $client->{agg_payment_usd}, '$' . $client->{balance_usd}, $client->{cashier_locked}, '$' . $client->{equity},
            $client->{last_access} . ' days', $client->{reason});

        $csv->combine(@row);
        print $csv->string;
    }

    code_exit_BO();
}

# Alert downloading csv with auto debit balance from disabled clients
my $on_submit_event;
if (request()->param('recoverfromfraudpassword') eq 'l') {
    $on_submit_event = 'onsubmit="return confirmDownloadCSV(' . encode_entities(request()->param('recoverdays')) . ');"';
}

# Show the "DOWNLOAD CSV" button.
print '<form method="post" id="download_csv_form" action="'
    . request()->url_for('backoffice/f_viewclientsubset.cgi') . '" '
    . $on_submit_event . ' >'
    . '<input type="hidden" name="show" value="'
    . $show . '">'
    . '<input type="hidden" name="onlylarge" value="'
    . encode_entities(request()->param('onlylarge')) . '">'
    . '<input type="hidden" name="onlyfunded" value="'
    . encode_entities(request()->param('onlyfunded')) . '" />'
    . '<input type="hidden" name="onlynonzerobalance" value="'
    . encode_entities(request()->param('onlynonzerobalance')) . '" />'
    . '<input type="hidden" name="broker" value="'
    . $broker . '">'
    . '<input type="submit" name="action" value="DOWNLOAD CSV" />'
    . '</form>';

Bar($show);

my $total_bal;

my $table_header = '<tr>'
    . '<th>LOGINID</th>'
    . '<th>NAME</th>'
    . '<th>COUNTRY</th>'
    . '<th>EMAIL</th>'
    . '<th>AGG. DEPOSITS<br />- WITHDRAWALS</th>'
    . '<th>CASH<br />BALANCE</th>'
    . '<th>Cashier</th>'
    . '<th>TOTAL EQUITY<br />& Expired contracts</th>'
    . '<th>Last access (in days)</th>'
    . '<th>Reason</th>' . '</tr>';

print '<br /><table border=1 cellpadding=0 cellspacing=0 width=95%>' . $table_header;

my $limit         = request()->param('limit') || 100;    # record to show per page
my $page_selected = request()->param('page')  || 1;      # selected page number
my $offsetfrom = $limit * ($page_selected - 1);

my $results = get_client_by_status({
    broker => $broker,
    show   => $show,
    limit  => $limit,
    offset => $offsetfrom
});

my $total = scalar keys %{$results};
my $email_notification;

CLIENT:
foreach my $loginID (keys %{$results}) {
    my $client      = $results->{$loginID};
    my $last_access = $client->{last_access};

    my $recover;
    if ($last_access > request()->param('recoverdays') and request()->param('recoverfromfraudpassword') eq 'l') {
        my $result = RecoverFromClientAccount({
            'loginID' => $loginID,
            'clerk'   => $clerk,
        });

        $recover = $result->{'msg'};
        if (exists $result->{'notification'}) {
            $email_notification .= $loginID . ' - ' . $result->{'notification'} . "\n\n";
        }
    }

    print "<tr>"
        . "<td>$loginID</td>" . "<td>"
        . encode_entities($client->{name})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{citizen})
        . "&nbsp;</td>"
        . "<td><font size=1>"
        . encode_entities($client->{email})
        . "&nbsp;</font></td>"
        . "<td>\$"
        . encode_entities($client->{agg_payment_usd}) . "</td>"
        . "<td>\$"
        . encode_entities($client->{balance_usd})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{cashier_locked})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{equity})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{last_access})
        . " days $recover &nbsp;</td>" . "<td>"
        . encode_entities($client->{reason})
        . "&nbsp;</td>" . "</tr>";

    $total_bal += $client->{balance_usd};
}

if ($email_notification) {
    my $brand = Brands->new(name => request()->brand);
    my $email_to = join(',', ($brand->emails('compliance'), $brand->emails('accounting')));

    my $ret = send_email({
        'from'    => $brand->emails('system'),
        'to'      => $email_to,
        'subject' => 'Funds withdrawn for disabled accounts',
        'message' => ["To be informed that the funds have been withdrawn for the following disabled account(s):\n\n$email_notification"],
    });

    if (not $ret) {
        print '<p style="font-weight:bold; color:red; text-align:center; padding:1em 0;"> Notification was not sent: Error '
            . encode_entities($ret) . ' </p>';
    }
}

# Page navigation
my ($prev_page, $next_page, $offset, $total_page, $next_total) = GetPagingParameter({
    'page'  => $page_selected,
    'total' => ($total || 0),
    'limit' => $limit,
});

my $paging;

if ($total) {
    if ($prev_page >= 1) {
        my $link = $home_link->clone;
        $link->query(
            broker                   => $broker,
            show                     => $show,
            limit                    => $limit,
            page                     => $prev_page,
            onlylarge                => request()->param('onlylarge'),
            onlyfunded               => request()->param('onlyfunded'),
            onlynonzerobalance       => request()->param('onlynonzerobalance'),
            recoverfromfraudpassword => request()->param('recoverfromfraudpassword'),
            recoverdays              => request()->param('recoverdays'),
        );
        $prev_page = '<a id="prev_page" href="' . $link . '">Previous ' . encode_entities($limit) . '</a>';
    } else {
        $prev_page = '';
    }

    if ($next_page <= $total_page) {
        my $link = $home_link->clone;
        $link->query(
            broker                   => $broker,
            show                     => $show,
            limit                    => $limit,
            page                     => $next_page,
            onlylarge                => request()->param('onlylarge'),
            onlyfunded               => request()->param('onlyfunded'),
            onlynonzerobalance       => request()->param('onlynonzerobalance'),
            recoverfromfraudpassword => request()->param('recoverfromfraudpassword'),
            recoverdays              => request()->param('recoverdays'),
        );

        $next_page = '<a id="next_page" href="' . $link . '">Next ' . encode_entities($next_total) . '</a>';
    } else {
        $next_page = '';
    }

    if ($next_page or $prev_page) {
        $paging =
              '<form class="paging" action="'
            . request()->url_for('backoffice/f_viewclientsubset.cgi')
            . '" method="post">'
            . '<input type="hidden" name="broker" value="'
            . $broker . '" />'
            . '<input type="hidden" name="limit" value="'
            . encode_entities($limit) . '" />'
            . '<input type="hidden" name="show" value="'
            . $show . '" />'
            . '<input type="hidden" name="onlylarge" value="'
            . encode_entities(request()->param('onlylarge')) . '" />'
            . '<input type="hidden" name="onlyfunded" value="'
            . encode_entities(request()->param('onlyfunded')) . '" />'
            . '<input type="hidden" name="onlynonzerobalance" value="'
            . encode_entities(request()->param('onlynonzerobalance')) . '" />'
            . '<input type="hidden" name="recoverfromfraudpassword" value="'
            . encode_entities(request()->param('recoverfromfraudpassword')) . '" />'
            . '<input type="hidden" name="recoverdays" value="'
            . encode_entities(request()->param('recoverdays')) . '" />'
            . $prev_page . ' <em>'
            . ' Page: <input size="3" maxlength="3" type="text" id="page_input" name="page" value="'
            . encode_entities($page_selected)
            . '" /> of '
            . encode_entities($total_page)
            . ' <input type="submit" value="Go" />'
            . '</em> '
            . $next_page
            . '</form>';
    }
}

print '<tr><td colspan="9" align="right">' . $paging . '</td></tr>';
print '</table>';

print '<p>Total a/c balances of clients in the list: USD ' . encode_entities($total_bal) . '</p><br />';

code_exit_BO();

sub get_client_by_status {
    my $args   = shift;
    my $broker = $args->{'broker'};
    my $show   = $args->{'show'};

    my ($limit, $offset);
    $limit  = $args->{limit}  if $args->{limit};
    $offset = $args->{offset} if $args->{offset};

    my %SUMMARYFILE;

    ## Read dailysummary file into memory
    my $yesterday = Date::Utility->new(time - 86400)->date_ddmmmyy;
    foreach my $curr (@{request()->available_currencies}) {
        my $summaryfilename =
            BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/dailysummary/" . $yesterday . ".summary";
        if ($curr ne 'USD') {
            $summaryfilename .= '.' . $curr;
        }
        if (open(my $sf, '<', $summaryfilename)) {    ## no critic (RequireBriefOpen)
            flock($sf, 1);
            while (my $l = <$sf>) {
                if ($l =~ /^(\D+\d+)\,(\w+)\,(\-?\d*\.?\d*)\,(\-?\d*\.?\d*)\,(\-?\d*\.?\d*)\,/) {
                    my $loginid    = $1;
                    my $liveordead = $2;
                    my $acbal      = $3;
                    my $openpl     = $4;
                    my $equity     = $5;
                    $SUMMARYFILE{"$loginid-TOTALEQUITY"} += roundcommon(0.01, in_USD($equity, $curr));
                }
            }
            close $sf;
        }
    }

    my $sql = q{
        WITH client as (
            SELECT
                loginid,
                salutation || ' ' || first_name || ' ' || last_name as name,
                email,
                citizen,
                t.status_code,
                t.reason,
                CASE WHEN s.status_code = 'cashier_locked' THEN 'LOCK' ELSE 'OPEN' END as cashier_locked
            FROM
                betonmarkets.client c
                JOIN
                (
                    SELECT * FROM betonmarkets.client_status
                    WHERE status_code = ?
                ) t ON c.loginid = t.client_loginid AND c.broker_code = ?
                LEFT JOIN
                (
                    SELECT * FROM betonmarkets.client_status
                    WHERE status_code = 'cashier_locked'
                ) s ON t.client_loginid = s.client_loginid
    };

    if ($limit and $offset) {
        $sql .= " LIMIT $limit OFFSET $offset ";
    }
    $sql .= q{
        ),

        funded as (
            SELECT
                c.loginid,
                count(*) as deposit_cnt
            FROM
                client c
                JOIN transaction.account a
                    ON c.loginid = a.client_loginid
                JOIN payment.payment p
                    ON a.id = p.account_id
            WHERE
                p.payment_gateway_code NOT IN ('free_gift', 'affiliate_reward')
                AND p.amount > 0
            GROUP BY 1
        )

        SELECT
            c.loginid,
            c.status_code,
            c.reason,
            c.cashier_locked,
            c.name,
            c.email,
            c.citizen,
            EXTRACT(DAY FROM (now() - a.last_modified)) as last_access,
            CASE
                WHEN f.deposit_cnt > 0 THEN 1
                ELSE 0
            END as funded,
            ROUND(a.balance * exch.rate, 2) as balance_usd,
            SUM(ROUND(p.amount * exch.rate, 2)) as agg_payment_usd
        FROM
            client c
            LEFT JOIN transaction.account a
                ON a.client_loginid = c.loginid AND a.is_default = TRUE
            LEFT JOIN data_collection.exchangetousd_rate(a.currency_code) exch(rate)
                ON true
            LEFT JOIN payment.payment p
                ON p.account_id = a.id
            LEFT JOIN funded f
                ON f.loginid = c.loginid
        GROUP BY 1,2,3,4,5,6,7,8,9,10
    };

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbic;
    my $results = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($show, $broker);
            return $sth->fetchall_hashref('loginid');
        });

    foreach my $loginID (keys %{$results}) {
        my $client = $results->{$loginID};

        if (request()->param('onlylarge') and $SUMMARYFILE{$loginID . '-TOTALEQUITY'} < 5) {
            delete $results->{$loginID};
            next;
        }
        if (request()->param('onlyfunded') && $client->{funded} == 0) {
            delete $results->{$loginID};
            next;
        }

        if (request()->param('onlynonzerobalance') && $client->{balance_usd} == 0) {
            delete $results->{$loginID};
            next;
        }
        my $bal = $client->{balance_usd};
        my $opencontracts = ($SUMMARYFILE{"$loginID-TOTALEQUITY"} > $bal) ? '$' . ($SUMMARYFILE{"$loginID-TOTALEQUITY"} - $bal) : '';
        $client->{equity} = $SUMMARYFILE{"$loginID-TOTALEQUITY"} . ' ' . $opencontracts;
    }
    return $results;
}

sub GetPagingParameter {
    my ($args) = @_;

    my $page = $args->{'page'} || 1;
    my $remain = $args->{'total'} % $args->{'limit'};
    #my $total_page    = ($args->{'total'} - $remain)/$args->{'limit'} + 1;
    my $total_page = POSIX::ceil($args->{'total'} / $args->{'limit'});
    my $offset     = $args->{'limit'} * $page - $args->{'limit'} + 1;
    my $next_page  = $page + 1;
    my $next_total = $remain && $next_page == $total_page ? $remain : $args->{'limit'};
    my $prev_page  = $page - 1;

    return ($prev_page, $next_page, $offset, $total_page, $next_total);
}

##################################################################################################
#
# Purpose: Performing following action:
#          1. Withdraw the balance from the disabled account
#          2. write into log file
#
##################################################################################################
sub RecoverFromClientAccount {
    my $arg_ref = shift;

    my $loginID = $arg_ref->{'loginID'};
    my $clerk   = $arg_ref->{'clerk'};

    my $result = {};

    my $broker;
    if ($loginID =~ /^(\D+)\d+$/) {
        $broker = $1;
    } else {
        die "[$0] bad loginID $loginID";
    }

    my $client = Client::Account::get_instance({'loginid' => $loginID})
        || die "[$0] RecoverFromClientAccount could not get client for $loginID";
    if (not $client->get_status('disabled')) {
        $result->{'msg'} = "span style='color:red;font-weight:bold;'>ERROR: $loginID ($broker) is not disabled</font>";
    }

    my $bal = BOM::Database::DataMapper::Account->new({
            client_loginid => $loginID,
            currency_code  => $client->currency
        })->get_balance();

    next CURRENCY if ($bal < 0.01);

    $client->payment_legacy_payment(
        currency     => $client->currency,
        amount       => -$bal,
        remark       => 'Inactive Account closed.',
        payment_type => 'closed_account',
        staff        => $clerk,
    );

    my $acc_balance = $client->currency . $bal;

    my $log = BOM::Backoffice::Config::config->{log}->{withdraw_broker};
    $log =~ s/%BROKERCODE%/$broker/g;
    Path::Tiny::path($log)->append_utf8(Date::Utility->new->datetime . " $loginID balance $acc_balance withdrawn by $clerk");

    $result->{'msg'}          = "<br><span style='color:green;font-weight:bold;'>RECOVERED $acc_balance</span>";
    $result->{'notification'} = $acc_balance;
    return $result;
}

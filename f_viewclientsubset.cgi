#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use POSIX ();
use Date::Utility;
use Path::Tiny;
use HTML::Entities;
use Format::Util::Numbers qw/roundcommon/;
use ExchangeRates::CurrencyConverter qw/in_usd/;
use Text::CSV;

use Brands;

use open qw[ :encoding(UTF-8) ];

use BOM::Database::DataMapper::Account;
use BOM::Backoffice::Request qw(request);
use BOM::Config::Runtime;
use BOM::Backoffice::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);
use BOM::Backoffice::Utility qw( master_live_server_error );
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

master_live_server_error() unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}));

my $show = encode_entities(request()->param('show') // "");
if (request()->param('action') ne 'DOWNLOAD CSV') {
    PrintContentType();
    BrokerPresentation("MONITOR $show");
}

my $broker = encode_entities(request()->broker_code // "");
my $clerk = BOM::Backoffice::Auth0::get_staffname();

my $home_link = request()->url_for('backoffice/f_viewclientsubset.cgi');
my @header    = (
    'LOGINID', 'NAME', 'COUNTRY', 'EMAIL', 'AGG. DEPOSITS - WITHDRAWALS',
    'CASH BALANCE', 'CASHIER',
    'TOTAL EQUITY & Expired contracts',
    'Last access (in days)', 'reason'
);

# This block of code shall come before PrintContentType, as PrintContentType will overwrite our
# intention of outputing CSV file.
if (request()->param('action') eq 'DOWNLOAD CSV') {
    PrintContentType_excel($broker . '-client.csv');

    my $csv = Text::CSV->new({
            binary       => 1,
            always_quote => 1,
            quote_char   => '"',
            eol          => "\n"
        })    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();

    $csv->combine(@header);
    print $csv->string;

    my $results = get_client_by_status({
        'broker' => $broker,
        'show'   => $show,
    });
    foreach my $loginid (keys %{$results}) {
        my $client = $results->{$loginid};
        my @row    = (
            $loginid,                  $client->{name},                           $client->{residence},
            $client->{email},          '$' . $client->{aggregate_payment_in_usd}, '$' . $client->{balance_in_usd},
            $client->{cashier_locked}, '$' . $client->{equity},                   $client->{last_access} . ' days',
            $client->{reason});

        $csv->combine(@row);
        print $csv->string;
    }

    code_exit_BO();
}

# Show the "DOWNLOAD CSV" button.
print '<form method="post" id="download_csv_form" action="'
    . request()->url_for('backoffice/f_viewclientsubset.cgi') . '">'
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

my $table_header = '<tr>' . (join '', map { "<th>$_</th>" } @header) . '</tr>';

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

CLIENT:
foreach my $loginID (keys %{$results}) {
    my $client      = $results->{$loginID};
    my $last_access = $client->{last_access};

    print "<tr>"
        . "<td>$loginID</td>" . "<td>"
        . encode_entities($client->{name})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{residence})
        . "&nbsp;</td>"
        . "<td><font size=1>"
        . encode_entities($client->{email})
        . "&nbsp;</font></td>"
        . "<td>\$"
        . encode_entities($client->{aggregate_payment_in_usd}) . "</td>"
        . "<td>\$"
        . encode_entities($client->{balance_in_usd})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{cashier_locked})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{equity})
        . "&nbsp;</td>" . "<td>"
        . encode_entities($client->{last_access})
        . " days &nbsp;</td>" . "<td>"
        . encode_entities($client->{reason})
        . "&nbsp;</td>" . "</tr>";

    $total_bal += $client->{balance_in_usd};
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
            broker             => $broker,
            show               => $show,
            limit              => $limit,
            page               => $prev_page,
            onlylarge          => request()->param('onlylarge'),
            onlyfunded         => request()->param('onlyfunded'),
            onlynonzerobalance => request()->param('onlynonzerobalance'),
        );
        $prev_page = '<a id="prev_page" href="' . $link . '">Previous ' . encode_entities($limit) . '</a>';
    } else {
        $prev_page = '';
    }

    if ($next_page <= $total_page) {
        my $link = $home_link->clone;
        $link->query(
            broker             => $broker,
            show               => $show,
            limit              => $limit,
            page               => $next_page,
            onlylarge          => request()->param('onlylarge'),
            onlyfunded         => request()->param('onlyfunded'),
            onlynonzerobalance => request()->param('onlynonzerobalance'),
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
    my $args = shift;

    my ($broker, $show, $limit, $offset) = @{$args}{qw/broker show limit offset/};

    my %SUMMARYFILE;
    ## Read dailysummary file into memory
    my $yesterday = Date::Utility->new(time - 86400)->date_ddmmmyy;
    foreach my $curr (@{request()->available_currencies}) {
        my $summaryfilename =
            BOM::Config::Runtime->instance->app_config->system->directory->db . "/f_broker/$broker/dailysummary/" . $yesterday . ".summary";
        if ($curr ne 'USD') {
            $summaryfilename .= '.' . $curr;
        }
        my $csv = Text::CSV->new({binary => 1})
            or die "Cannot use CSV: " . Text::CSV->error_diag();

        if (open my $fh, "<:encoding(utf8)", $summaryfilename) {    ## no critic (RequireBriefOpen)
            flock($fh, 1);
            while (my $row = $csv->getline($fh)) {
                # consider only when line starts with loginid
                # sample record entry
                # loginid,account_balance,total_open_bets_value,total_open_bets_profit,
                # total_equity,aggregate_deposit_withdrawals,portfolio
                next if $row->[0] !~ /^([A-Z]+)\d+$/;
                $SUMMARYFILE{$row->[0] . "-TOTALEQUITY"} += roundcommon(0.01, in_usd($row->[4], $curr)) if $row->[4];
            }
            $csv->eof or $csv->error_diag();
            close $fh;
        }
    }

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbic;
    my $results = $dbic->run(
        ping => sub {
            my $sth = $_->prepare(
                'SELECT client_loginid, status_code, reason, cashier_locked,
                name, email, residence, last_access, funded, balance_in_usd,
                aggregate_payment_in_usd FROM reporting.get_client_list_by_status(?, ?, ?)'
            );
            $sth->execute($show, $limit, $offset);
            return $sth->fetchall_hashref('client_loginid');
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

        if (request()->param('onlynonzerobalance') && $client->{balance_in_usd} == 0) {
            delete $results->{$loginID};
            next;
        }
        my $bal = $client->{balance_in_usd};
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

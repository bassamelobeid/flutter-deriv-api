#!/usr/bin/perl
package main;
use strict 'vars';

use Locale::Country;
use DateTime;
use JSON;

use f_brokerincludeall;
use BOM::Platform::Data::Persistence::DataMapper::Payment;
use BOM::Platform::Data::Persistence::DataMapper::Transaction;
use BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet;
use BOM::Database::AutoGenerated::Rose::PromoCode::Manager;
use File::stat qw( stat );
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('MARKETING TOOLS');

my %input  = %{request()->params};
my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access(['Marketing']);

my $where = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/affiliates/' . $broker;
if (not -d $where) {
    system("mkdir -p $where");
}

# Promotional codes
Bar('Promotional codes');

my $dbclass = 'BOM::Database::AutoGenerated::Rose::PromoCode';

my $db = $dbclass->new(broker => $broker)->db;
my $pcs = "${dbclass}::Manager"->get_promo_code(
    db      => $db,
    sort_by => 'code'
);

if (@$pcs) {

    my %pcs_by_currency;
    for my $pc (@$pcs) {
        $pc->{_json} ||= eval { JSON::from_json($pc->promo_code_config) } || {};
        my $currency = $pc->{_json}->{currency} || next;
        $pcs_by_currency{$currency}++;
    }

    my %expiry_select = (
        'All expiry date'  => '',
        'Expired only'     => '1',
        'Non expired only' => '2',
    );

    print '<p>Show ';
    print '<select id=expiry_select>';
    my $expiry_selected;
    $input{expiry_select} //= '2';
    foreach my $label (sort keys %expiry_select) {
        if ($expiry_select{$label} == $input{expiry_select}) {
            $expiry_selected = 'selected="selected"';
        } else {
            $expiry_selected = '';
        }
        print '<option value="' . $expiry_select{$label} . '" ' . $expiry_selected . '>' . $label . '</option>';
    }
    print '</select>';

    print ' for:</p>';
    print '<ul>';

    foreach my $currency_label (sort keys %pcs_by_currency) {
        print '<li>
                <a href="'
            . request()->url_for(
            'backoffice/f_promotional.cgi',
            {
                currency_only => $currency_label,
                broker        => $broker
            })
            . '" onclick="window.location= this.href + \'&expiry_select=\' + document.getElementById(\'expiry_select\').value;return(false);">'
            . $currency_label
            . ' currency' . '</a>
            </li>';
    }

    print '<li>'
        . '<a href="'
        . request()->url_for(
        'backoffice/f_promotional.cgi',
        {
            currency_only => '',
            broker        => $broker
        })
        . '" onclick="window.location= this.href + \'&expiry_select=\' + document.getElementById(\'expiry_select\').value;return(false);">ALL Promocodes
            </a>
        </li>
    </ul>';

    print 'The Free Gift promotional codes are :';
    print '
        <table border=1 cellpading=0 cellspacing=0>
            <tr>
                <td><b>CODE</td>
                <td><b>AMOUNT</td>
                <td><b>MIN DEPOSIT</td>
                <td><b>MIN TURNOVER</td>
                <td><b>START DATE<br></td>
                <td><b>EXPIRY DATE<br>(red=expired)</td>
                <td><b>TYPE</td>
                <td><b>COUNTRY</td>
                <td><b>DESCRIPTION</td>
                <td><b>STATUS</td>
                <td><b>EDIT</td>
            </tr>';

    POROMOCODES_TABLE:
    foreach my $pc (@$pcs) {

        my $pc_currency = $pc->{_json}->{currency} || next;
        my $red;

        # skip not wanted currency
        next POROMOCODES_TABLE if $input{currency_only} && $input{currency_only} ne $pc_currency;

        my $expiry_date;
        if ($pc->expiry_date && $pc->expiry_date < DateTime->now) {
            next POROMOCODES_TABLE if $input{expiry_select} == 2;
            $expiry_date = '<font color="red">' . $pc->expiry_date->ymd . '</font>';
        } elsif ($pc->expiry_date) {
            next POROMOCODES_TABLE if $input{expiry_select} == 1;
            $expiry_date = $pc->expiry_date->ymd;
        }

        my $amount = $pc_currency . $pc->{_json}->{amount};

        my @countries =
            map { /ALL/ ? 'ALL' : BOM::Platform::Runtime->instance->countries->country_from_code($_) } split(/,/, $pc->{_json}->{country});

        my $href = request()->url_for(
            'backoffice/promocode_edit.cgi',
            {
                broker    => $broker,
                promocode => $pc->code,
            });
        my $link = qq[<a target="_blank" href="$href">Edit</a>];

        print '<tr>' . '<td>' . '<b>'
            . $pc->code . '</b>' . '</td>' . '<td>'
            . $amount . '</td>' . '<td>'
            . ($pc->{_json}->{min_deposit}  || '&nbsp;') . '</td>' . '<td>'
            . ($pc->{_json}->{min_turnover} || '&nbsp;') . '</td>' . '<td>'
            . ($pc->start_date              || '&nbsp;') . '</td>' . '<td>'
            . ($expiry_date                 || '&nbsp;') . '</td>' . '<td>'
            . $pc->promo_code_type . '</td>' . '<td>'
            . join(', ', @countries) . '</td>' . '<td>'
            . ($pc->description || '&nbsp') . '</td>' . '<td>'
            . ($pc->status ? 'TRUE' : 'FALSE') . '</td>' . '<td>'
            . $link . '</td>' . '</tr>';
    }

    print '</table>';
}

print '<i>Note: to track signups, see the log files in the Perl log files section.</i>';

# Adding new promocode
print '<br><hr>' . '<p><b>' . '<font color=green size=3>Add new promocode: </font>' . '</b></p>';

print '<form method=get action="'
    . request()->url_for('backoffice/promocode_edit.cgi') . '">'
    . '<input name=broker value='
    . $broker
    . ' type=hidden></input>'
    . '<input type=submit value="Add new promocode"> Note: Click this button to add new promocode'
    . '</form>';

# PROMO CODE APPROVAL TOOL
Bar('PROMO CODE APPROVAL TOOL');

my ($output, $table_elements, $input_elements);

my $table_header =
      '<br /><form method="post" action="'
    . request()->url_for('backoffice/f_promotional_processing.cgi') . '">'
    . '<table border=1 cellpadding=3 cellspacing=1 id="PROMO_CODE_APPROVAL" class="sortable">' . '<tr>'
    . '<th>Approve</th>'
    . '<th>Reject</th>'
    . '<th>Date/Time</th>'
    . '<th>Promocode</th>'
    . '<th>Code type</th>'
    . '<th>Bonus</th>'
    . '<th>LoginID</th>'
    . '<th>Name</th>'
    . '<th>Residence</th>'
    . '<th>Referer</th>'
    . '<th>IP address</th>'
    . '<th>Turnover</th>'
    . '<th># of bets bought</th>'
    . '<th>Account age</th>'
    . '<th>Authenticated?</th>'
    . '<th>Account status</th>'
    . '<th>Notify client?</th>'
    . '<th>Further details</th>' . '</tr>';

my @clients = BOM::Platform::Client->by_promo_code(
    broker_code => $broker,
    status      => 'APPROVAL'
);

foreach my $client (@clients) {
    my $client_login = $client->loginid;
    next unless ($client->promo_code_status || '') eq 'APPROVAL';
    my $dodgy =
           $client->get_status('disabled')
        || $client->get_status('cashier_locked')
        || $client->get_status('unwelcome')
        || $client->documents_expired;
    my $color = $dodgy ? 'red' : '';
    my $disabled = $dodgy ? 'disabled="disabled"' : '';
    my $client_name          = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $client_residence     = Locale::Country::code2country($client->residence);
    my $client_authenticated = ($client->client_fully_authenticated) ? 'yes' : 'no';
    my $datetime             = $client->promo_code_apply_date;

    my $client_ip = $client->latest_environment;
    if ($client_ip =~ /(\d+\.\d+\.\d+\.\d+)/) {
        $client_ip = $1;
    }

    my $account_age;
    my $now         = BOM::Utility::Date->new;
    my $date_joined = $client->date_joined;

    if ($date_joined) {
        my $joined = BOM::Utility::Date->new($date_joined);
        $date_joined = $joined->date_ddmmmyy;
        $account_age = $now->days_between($joined);

        if ($account_age eq 0) {
            $account_age = 'account opened today';
        } elsif ($account_age > 1) {
            $account_age = $account_age . ' days';
        } else {
            $account_age = $account_age . ' day';
        }
    }

    my $cpc = $client->client_promo_code || die "$client must have a client-promo-code by now";
    my $pc = $cpc->promotion;
    $pc->{_json} ||= eval { JSON::from_json($pc->promo_code_config) } || {};

    my $currency = $pc->{_json}->{currency};
    if ($currency eq 'ALL') {
        $currency = $client->currency;
    }

    my $total_turnover;
    my $txn_mapper = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
        client_loginid => $client_login,
        currency_code  => $client->currency,
    });
    my $account_turnover = $txn_mapper->get_turnover_of_account;

    if ($account_turnover > 0) {
        $total_turnover .= $currency . sprintf("%.2f", $account_turnover) . ' ';
    }

    my $bet_mapper = BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet->new({client_loginid => $client_login});
    my $total_bets = $bet_mapper->get_bet_count_of_client;

    $total_turnover ||= '&nbsp;';
    $total_bets     ||= '&nbsp;';

    my $clientdetail_link = '<a href="'
        . request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $broker,
            loginID => $client_login
        }) . '" target=_blank>client details</a>';
    my $statement_link = '<a href="'
        . request()->url_for(
        'backoffice/f_manager_history.cgi',
        {
            broker   => $broker,
            loginID  => $client_login,
            currency => 'All',
        }) . '" target=_blank>statement</a>';

    my $check_account =
          $client->get_status('disabled')       ? 'account disabled'
        : $client->get_status('cashier_locked') ? 'cashier locked'
        : $client->get_status('unwelcome')      ? 'unwelcome login'
        : $client->documents_expired            ? 'documents expired'
        :                                         '';

    $table_elements .= qq[
        <tr>
            <td><center><input name="${client_login}_promo" value="A" type="radio" $disabled ></center></td>
            <td><center><input name="${client_login}_promo" value="R" type="radio"           ></center></td>
            <td><font color="$color">$datetime</font></td>
            <td><font color="$color">${\($pc->code)}</font></td>
            <td><font color="$color">${\($pc->promo_code_type)}</font></td>
            <td><font color="$color">$pc->{_json}->{currency}$pc->{_json}->{amount}</font></td>
            <td><font color="$color">$client_login</font></td>
            <td><font color="$color">$client_name</font></td>
            <td><font color="$color">$client_residence</font></td>
            <td><font color="$color">&nbsp;</font></td>
            <td><font color="$color">$client_ip</font></td>
            <td><font color="$color">$total_turnover</font></td>
            <td><font color="$color">$total_bets</font></td>
            <td><font color="$color">$account_age</font></td>
            <td><font color="$color">$client_authenticated</font></td>
            <td><font color="$color">$check_account</font</td>
            <td><center><input name="${client_login}_notify" type="checkbox" checked="checked"></center></td>
            <td>$clientdetail_link, $statement_link</td>
        </tr>
    ]
}

my $table_end .=
      '</table>'
    . '<br /><input type="submit" value="Save">'
    . '<input type=hidden name="save_file" value="save">'
    . '<input type=hidden name="broker" value="'
    . $broker . '">'
    . '</form>';

if ($table_elements) {
    $output .= $table_header . $table_elements . $table_end;
} else {
    $output .= '<br /><p>There are no clients in the pending promotional code approval list.</p><br />';
}

print $output;

Bar('Bulk-add client affiliate exposures.');
BOM::Platform::Context::template->process(
    'backoffice/bulkadd_exposures.html.tt',
    {
        action => request()->url_for('backoffice/bulkadd_exposures.cgi'),
    },
);

Bar('Fetch Myaffiliate Payment');
BOM::Platform::Context::template->process(
    'backoffice/fetch_myaffiliate_payment.tt',
    {
        action => request()->url_for('backoffice/fetch_myaffiliate_payment.cgi'),
    },
);

code_exit_BO();

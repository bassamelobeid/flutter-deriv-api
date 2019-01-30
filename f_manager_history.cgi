#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Text::Trim qw(trim);
use Locale::Country;
use f_brokerincludeall;
use HTML::Entities;
use Date::Utility;

use BOM::User::Client;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Database::ClientDB;
use BOM::ContractInfo;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
use Format::Util::Numbers qw/formatnumber/;

PrintContentType();

my $loginID = uc(request()->param('loginID') // '');
$loginID =~ s/\s//g;

my $encoded_loginID = encode_entities($loginID);
my $depositswithdrawalsonly = request()->param('depositswithdrawalsonly') // '';

my $from_date = trim(request()->param('startdate'));
my $to_date   = trim(request()->param('enddate'));

if ($from_date && $to_date && $from_date =~ m/^\d{4}-\d{2}-\d{2}$/ && $to_date =~ m/^\d{4}-\d{2}-\d{2}$/) {
    $from_date .= ' 00:00:00';
    $to_date   .= ' 23:59:59';
}
$to_date   = ($to_date)   ? Date::Utility->new($to_date)   : undef;
$from_date = ($from_date) ? Date::Utility->new($from_date) : undef;

my $overview_from_date =
    request()->param('overview_fm_date') ? Date::Utility->new(request()->param('overview_fm_date')) : Date::Utility->new()->_minus_months(6);
my $overview_to_date =
    request()->param('overview_to_date') ? Date::Utility->new(request()->param('overview_to_date')) : Date::Utility->new();

$overview_from_date = Date::Utility->new($overview_from_date->date_yyyymmdd() . " 00:00:00");
$overview_to_date   = Date::Utility->new($overview_to_date->date_yyyymmdd() . " 23:59:59");

my $broker;
if ($loginID =~ /^([A-Z]+)/) {
    $broker = $1;
}

BrokerPresentation($encoded_loginID . ' HISTORY', '', '');
unless ($broker) {
    print 'Error : wrong loginID ' . $encoded_loginID;
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginID,
    db_operation => 'replica'
});

if (not $client) {
    Bar($loginID);
    print "<div style='color:red' class='center-aligned'>Error : wrong loginID ($encoded_loginID) could not get client instance</div>";
    code_exit_BO();
}

my $loginid_bar = $loginID;
$loginid_bar .= ' (DEPO & WITH ONLY)' if ($depositswithdrawalsonly eq 'yes');
my $pa = $client->payment_agent;

Bar($loginid_bar);
print "<span style='color:red; font-weight:bold; font-size:14px'>PAYMENT AGENT</span>" if ($pa and $pa->is_authenticated);

# We either choose the dropdown currency from transaction page or use the client currency for quick jump
my $currency = $client->currency;
if (my $currency_dropdown = request()->param('currency_dropdown')) {
    $currency = $currency_dropdown unless $currency_dropdown eq 'default';
}

# initialize value to undef for conditional checking in statement.html.tt
my $total_deposits;
my $total_withdrawals;

# Fetch and display gross deposits and gross withdrawals
my $action = request()->param('action');
if (defined $action && $action eq "gross_transactions") {
    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
    if (!$client->account) {
        print "<div style='color:red' class='center-aligned'>Error: Client $loginID does not have currency set. </div>";
    }
    try {
        ($total_deposits, $total_withdrawals) = $clientdb->db->dbic->run(
            fixup => sub {
                my $statement = $_->prepare("SELECT * FROM betonmarkets.get_total_deposits_and_withdrawals(?)");
                $statement->execute($client->account->id);
                return @{$statement->fetchrow_arrayref};
            });
        $total_deposits    = formatnumber('amount', $currency, $total_deposits);
        $total_withdrawals = formatnumber('amount', $currency, $total_withdrawals);
    }
    catch {
        warn "Error caught : $_\n";
        print "<div style='color:red' class='center-aligned'>Error: Unable to fetch total deposits/withdrawals </div>";
    };
}

# print other untrusted section warning in backoffice
print build_client_warning_message(encode_entities($client->loginid)) . '<br />';

my $tel          = $client->phone;
my $citizen      = Locale::Country::code2country($client->citizen);
my $residence    = Locale::Country::code2country($client->residence);
my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $client_email = $client->email;

my $all_in_one_page = request()->checkbox_param('all_in_one_page');

# since client_statement_for_backoffice uses after (> sign) and before (< sign)
# we want the time to be inclusive of from_date (>= sign) and to_date (<= sign)
# so we add and minus 1 second to make it same as >= or <=
# underlying of client_statement_for_backoffice uses get_transactions and get_payments
# which handles undef accordingly.
my $statement = client_statement_for_backoffice({
        client => $client,
        after  => (not $all_in_one_page and $from_date)
        ? $from_date->minus_time_interval('1s')->datetime_yyyymmdd_hhmmss()
        : undef,
        before => (not $all_in_one_page and $to_date) ? $to_date->plus_time_interval('1s')->datetime_yyyymmdd_hhmmss() : undef,
        currency            => $currency,
        max_number_of_lines => ($all_in_one_page ? 99999 : 200),
    });
my $summary = client_statement_summary({
        client   => $client,
        currency => $currency,
        after    => $overview_from_date->datetime(),
        before   => $overview_to_date->datetime()});

my $appdb = BOM::Database::Model::OAuth->new();
my @ids   = map { $_->{source} || () } @{$statement->{transactions}};
my $apps  = $appdb->get_names_by_app_id(\@ids);

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement.html.tt',
    {
        client_summary_ranges => {
            from => $overview_from_date->date_yyyymmdd(),
            to   => $overview_to_date->date_yyyymmdd()
        },
        transactions            => $statement->{transactions},
        apps                    => $apps,
        balance                 => $statement->{balance},
        currency                => $currency,
        loginid                 => $client->loginid,
        broker                  => $broker,
        depositswithdrawalsonly => $depositswithdrawalsonly,
        contract_details        => \&BOM::ContractInfo::get_info,
        clientedit_url          => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
        self_post               => request()->url_for('backoffice/f_manager_history.cgi'),
        summary                 => $summary,
        total_deposits          => $total_deposits,
        total_withdrawals       => $total_withdrawals,
        client                  => {
            name        => $client_name,
            email       => $client_email,
            country     => $citizen,
            residence   => $residence,
            tel         => $tel,
            date_joined => $client->date_joined,
        },
        startdate => (not $all_in_one_page and $from_date) ? $from_date->datetime_yyyymmdd_hhmmss() : undef,
        enddate   => (not $all_in_one_page and $to_date)   ? $to_date->datetime_yyyymmdd_hhmmss()   : undef,
    },
) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();

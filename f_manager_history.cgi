#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no indirect;

use Text::Trim qw(trim);
use Locale::Country;
use f_brokerincludeall;
use HTML::Entities;
use Date::Utility;
use YAML::XS;
use List::Util qw(max);
use ExchangeRates::CurrencyConverter qw(in_usd);
use Format::Util::Numbers qw(formatnumber);
use Syntax::Keyword::Try;
use LandingCompany::Registry;

use BOM::User::Client;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Database::ClientDB;
use BOM::ContractInfo;
use BOM::Backoffice::Sysinit ();
use BOM::Config;
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $loginID = uc(request()->param('loginID') // '');
$loginID =~ s/\s//g;

my $encoded_loginID = encode_entities($loginID);

my $dw_param                = request()->param('depositswithdrawalsonly');
my $deposit_withdrawal_only = $dw_param && $dw_param eq 'yes' ? 1 : 0;

my $from_date = trim(request()->param('startdate'));
my $to_date   = trim(request()->param('enddate'));

if ($from_date && $to_date && $from_date =~ m/^\d{4}-\d{2}-\d{2}$/ && $to_date =~ m/^\d{4}-\d{2}-\d{2}$/) {
    $from_date .= ' 00:00:00';
    $to_date   .= ' 23:59:59';
}

my ($overview_from_date, $overview_to_date);
try {
    $to_date   = ($to_date)   ? Date::Utility->new($to_date)   : undef;
    $from_date = ($from_date) ? Date::Utility->new($from_date) : undef;
    $overview_from_date =
        request()->param('overview_fm_date') ? Date::Utility->new(request()->param('overview_fm_date')) : Date::Utility->new()->_minus_months(6);
    $overview_to_date =
        request()->param('overview_to_date') ? Date::Utility->new(request()->param('overview_to_date')) : Date::Utility->new();
} catch {
    code_exit_BO('Error: Wrong date entered.');
}

$overview_from_date = Date::Utility->new($overview_from_date->date_yyyymmdd() . " 00:00:00");
$overview_to_date   = Date::Utility->new($overview_to_date->date_yyyymmdd() . " 23:59:59");

my $broker;
if ($loginID =~ /^([A-Z]+)/) {
    $broker = $1;
}

BrokerPresentation($encoded_loginID . ' HISTORY', '', '');
unless ($broker) {
    code_exit_BO("Error: Wrong Login ID $encoded_loginID");
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginID, db_operation => 'backoffice_replica'}) };

if (not $client) {
    code_exit_BO("Error: Wrong Login ID ($encoded_loginID) could not get client instance.", $loginID);
}

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});

my $loginid_bar = $loginID;
$loginid_bar .= ' (DEPO & WITH ONLY)' if ($deposit_withdrawal_only);
my $pa = $client->payment_agent;

Bar($loginid_bar);
print "<span class='error'>PAYMENT AGENT</span>" if ($pa and $pa->is_authenticated);

# We either choose the dropdown currency from transaction page or use the client currency for quick jump
my $currency         = $client->currency;
my $currency_wrapper = BOM::CTC::Currency->new(currency_code => $client->currency);
if (my $currency_dropdown = request()->param('currency_dropdown')) {
    $currency = $currency_dropdown unless $currency_dropdown eq 'default';
}

# initialize value to undef for conditional checking in statement.html.tt
my $total_deposits;
my $total_withdrawals;

# Fetch and display gross deposits and gross withdrawals
my $action = request()->param('action');
if (defined $action && $action eq "gross_transactions") {
    if (my $account = $client->account) {
        try {
            ($total_deposits, $total_withdrawals) = $clientdb->db->dbic->run(
                fixup => sub {
                    my $statement = $_->prepare("SELECT * FROM betonmarkets.get_total_deposits_and_withdrawals(?)");
                    $statement->execute($account->id);
                    return @{$statement->fetchrow_arrayref};
                });
            $total_deposits    = formatnumber('amount', $currency, $total_deposits);
            $total_withdrawals = formatnumber('amount', $currency, $total_withdrawals);
        } catch ($e) {
            warn "Error caught : $e\n";
            print "<div class='error center'>Error: Unable to fetch total deposits/withdrawals </div>";
        }
    } else {
        print "<div class='error center'>Error: Client $loginID does not have currency set. </div>";
    }
}

# print other untrusted section warning in backoffice
print build_client_warning_message(encode_entities($client->loginid));

my $tel          = $client->phone;
my $citizen      = Locale::Country::code2country($client->citizen);
my $residence    = Locale::Country::code2country($client->residence);
my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $client_email = $client->email;

my $all_in_one_page = request()->checkbox_param('all_in_one_page');

my $summary = client_statement_summary({
    client   => $client,
    currency => $currency,
    from     => $overview_from_date->datetime(),
    to       => $overview_to_date->datetime(),
});

# since get_transactions_details uses `from` (> sign) and `to` (< sign)
# we want the time to be inclusive of from_date (>= sign) and to_date (<= sign)
# so we add and minus 1 second to make it same as >= or <=
# underlying of get_transactions_details uses get_transactions and get_payments
# which handles undef accordingly.
my $transaction_id = request()->param('transactionID');
my $transactions   = get_transactions_details({
        client   => $client,
        currency => $currency,
        from     => (not $all_in_one_page and $from_date) ? $from_date->minus_time_interval('1s')->datetime_yyyymmdd_hhmmss()
        : undef,
        to => (not $all_in_one_page and $to_date) ? $to_date->plus_time_interval('1s')->datetime_yyyymmdd_hhmmss()
        : undef,
        dw_only        => $deposit_withdrawal_only,
        limit          => $all_in_one_page ? 99999 : 200,
        transaction_id => $transaction_id,
    });

my $balance = client_balance($client, $currency);

my $appdb = BOM::Database::Model::OAuth->new();
my @ids   = map { $_->{source} || () } @{$transactions};
my $apps  = $appdb->get_names_by_app_id(\@ids);

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement.html.tt',
    {
        client_summary_ranges => {
            from => $overview_from_date->date_yyyymmdd(),
            to   => $overview_to_date->date_yyyymmdd()
        },
        transactions            => $transactions,
        transaction_id          => $transaction_id,
        apps                    => $apps,
        balance                 => $balance,
        now                     => Date::Utility->today,
        currency                => $currency,
        loginid                 => $client->loginid,
        broker                  => $broker,
        depositswithdrawalsonly => $deposit_withdrawal_only ? 'yes' : 'no',
        contract_details        => \&BOM::ContractInfo::get_info,
        self_post               => request()->url_for('backoffice/f_manager_history.cgi'),
        clientedit_url          => request()->url_for(
            'backoffice/f_clientloginid_edit.cgi',
            {
                loginID => $client->loginid,
                broker  => $broker
            }
        ),
        profit_url => request()->url_for(
            'backoffice/f_profit_check.cgi',
            {
                broker    => $broker,
                loginID   => $client->loginid,
                startdate => Date::Utility->today()->_minus_months(1)->date,
                enddate   => Date::Utility->today()->date,
            }
        ),
        crypto_statement_url => request()->url_for(
            'backoffice/f_manager_crypto_history.cgi',
            {
                loginID => $loginID,
                broker  => $client->broker,
            }
        ),
        summary           => $summary,
        total_deposits    => $total_deposits,
        total_withdrawals => $total_withdrawals,
        client            => {
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

BarEnd();

code_exit_BO();

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

my $startdate = trim(request()->param('startdate'));
my $enddate   = trim(request()->param('enddate'));

if ($startdate && $enddate && $startdate =~ m/^\d{4}-\d{2}-\d{2}$/ && $enddate =~ m/^\d{4}-\d{2}-\d{2}$/) {
    $startdate .= ' 00:00:00';
    $enddate   .= ' 23:59:59';
}

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

if ($depositswithdrawalsonly eq 'yes') {
    Bar($loginID . ' (DEPO & WITH ONLY)');
} else {
    Bar($loginID);
}

my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginID,
    db_operation => 'replica'
});
if (not $client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $currency = request()->param('currency');
if (not $currency or $currency eq 'default') {
    $currency = $client->currency;
}

# print other untrusted section warning in backoffice
print build_client_warning_message(encode_entities($client->loginid)) . '<br />';

my $tel          = $client->phone;
my $citizen      = Locale::Country::code2country($client->citizen);
my $residence    = Locale::Country::code2country($client->residence);
my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $client_email = $client->email;

my $statement = client_statement_for_backoffice({
    client   => $client,
    before   => $enddate,
    after    => $startdate,
    currency => $currency,
});

my $summary = client_statement_summary({
        client   => $client,
        currency => $currency,
        after    => $overview_from_date->datetime(),
        before   => $overview_to_date->datetime()});

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
my $dbic = $clientdb->db->dbic;

my ($deposits_to_date, $withdrawals_to_date) = $dbic->run(
    fixup => sub {
        my $sth = $_->prepare("SELECT * FROM betonmarkets.get_total_deposits_and_withdrawals(?, ?)");
        $sth->execute($client->loginid, $currency);
        return @{$sth->fetchall_arrayref->[0]};
    });

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement.html.tt',
    {

        client_summary_ranges => {
            from => $overview_from_date->date_yyyymmdd(),
            to   => $overview_to_date->date_yyyymmdd()
        },
        transactions            => $statement->{transactions},
        withdrawals_to_date     => formatnumber('amount', $currency, $withdrawals_to_date),
        deposits_to_date        => formatnumber('amount', $currency, $deposits_to_date),
        balance                 => $statement->{balance},
        currency                => $currency,
        loginid                 => $client->loginid,
        broker                  => $broker,
        depositswithdrawalsonly => $depositswithdrawalsonly,
        contract_details        => \&BOM::ContractInfo::get_info,
        clientedit_url          => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
        self_post               => request()->url_for('backoffice/f_manager_history.cgi'),
        summary                 => $summary,
        client                  => {
            name      => $client_name,
            email     => $client_email,
            country   => $citizen,
            residence => $residence,
            tel       => $tel
        },
        startdate => $startdate,
        enddate   => $enddate,
    },
) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();

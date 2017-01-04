#!/etc/rmg/bin/perl
package main;
use strict 'vars';

use Locale::Country;
use f_brokerincludeall;
use HTML::Entities;
use Client::Account;

use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::ContractInfo;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $loginID = uc(request()->param('loginID'));
my $encoded_loginID = encode_entities($loginID);
PrintContentType();
BrokerPresentation($loginID . ' HISTORY', '', '');
BOM::Backoffice::Auth0::can_access(['CS']);

my $broker;
if ($loginID =~ /^([A-Z]+)/) {
    $broker = $1;
}

$loginID =~ s/\s//g;
if ($loginID !~ /^$broker/) {
    print 'Error : wrong loginID ' . $encoded_loginID;
    code_exit_BO();
}

my $startdate = request()->param('startdate');
my $enddate   = request()->param('enddate');

$loginID =~ /^(\D+)(\d+)$/;

if (request()->param('depositswithdrawalsonly') eq 'yes') {
    Bar($loginID . ' (DEPO & WITH ONLY)');
} else {
    Bar($loginID);
}

my $client = Client::Account::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $currency = request()->param('currency');
if (not $currency or $currency eq 'default') {
    $currency = $client->currency;
}

# print other untrusted section warning in backoffice
print build_client_warning_message($client->loginid) . '<br />';

my $tel          = $client->phone;
my $citizen      = Locale::Country::code2country($client->citizen);
my $residence    = Locale::Country::code2country($client->residence);
my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $client_email = $client->email;

print '<form action="'
    . request()->url_for('backoffice/f_clientloginid_edit.cgi')
    . '" method=post>'
    . '<input type=hidden name=broker value='
    . $broker . '>'
    . '<input type=hidden name=loginID value='
    . $loginID . '>'
    . '<input type=submit value="View/edit '
    . $loginID
    . ' details">'
    . '</form>';

print '<table width=100%>' . '<tr>'
    . '<form  action="'
    . request()->url_for('backoffice/f_manager_history.cgi')
    . '" method=post>'
    . '<td align=right> Quick jump to see another statement: <input name=loginID type=text size=15 value='
    . $loginID . '>'
    . '<input type=hidden name=broker value='
    . $broker . '>'
    . '<input type=hidden name=l value=EN>'
    . '<input type=submit value=view>'
    . '<input type=checkbox value=yes name=depositswithdrawalsonly>Deposits and Withdrawals only' . '</td>'
    . '</form>' . '</tr>'
    . '</table><hr>';

my $senvs = $ENV{'SCRIPT_NAME'};
$ENV{'SCRIPT_NAME'} = '';
$ENV{'SCRIPT_NAME'} = $senvs;

print $client_name . ' Email:' . $client_email . ' Country:' . $citizen . ' Residence:' . $residence;
if ($tel) {
    print ' Tel:' . $tel;
}
print '<br />';

my $statement = client_statement_for_backoffice({
    client   => $client,
    before   => $enddate,
    after    => $startdate,
    currency => $currency,
});

BOM::Backoffice::Request::template->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $statement->{transactions},
        balance                 => $statement->{balance},
        currency                => $currency,
        loginid                 => $client->loginid,
        depositswithdrawalsonly => request()->param('depositswithdrawalsonly'),
        contract_details        => \&BOM::ContractInfo::get_info,
    },
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();


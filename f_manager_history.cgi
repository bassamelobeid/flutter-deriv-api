#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Locale::Country;
use f_brokerincludeall;
use HTML::Entities;
use Client::Account;

use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::ContractInfo;
use BOM::Database::DataMapper::Payment qw/get_total_withdrawal/;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $loginID = uc(request()->param('loginID') // '');
$loginID =~ s/\s//g;
my $encoded_loginID         = encode_entities($loginID);
my $depositswithdrawalsonly = request()->param('depositswithdrawalsonly') // '';
my $startdate               = request()->param('startdate');
my $enddate                 = request()->param('enddate');
my $months                  = request()->param('months') // 6;
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
    after    => Date::Utility->new(time - $months * 31 * 86400)->datetime,
    before   => Date::Utility->new()->datetime,
});

my $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => $client->loginid,
            currency_code  => $currency,
        });

BOM::Backoffice::Request::template->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $statement->{transactions},
        withdrawals_to_date     => $payment_mapper->get_total_withdrawal(),
        balance                 => $statement->{balance},
        currency                => $currency,
        loginid                 => $client->loginid,
        broker                  => $broker,
        depositswithdrawalsonly => $depositswithdrawalsonly,
        contract_details        => \&BOM::ContractInfo::get_info,
        clientedit_url          => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
        self_post               => request()->url_for('backoffice/f_manager_history.cgi'),
        summary                 => $summary,
        months                  => $months,
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
) || die BOM::Backoffice::Request::template->error();

code_exit_BO();


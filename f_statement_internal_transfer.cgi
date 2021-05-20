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

my $loginid = uc(request()->param('loginID') // '');
$loginid =~ s/\s//g;
my $encoded_loginid = encode_entities($loginid);

my $transfer_type  = request()->param('transfer_type') // 'payment_agent_transfer';
my $fellow_account = request()->param('fellow_account');
my $api_call       = request()->param('api_call');

my $from_date = trim(request()->param('from_date'));
my $to_date   = trim(request()->param('to_date'));
try {
    $from_date =
        $from_date ? Date::Utility->new($from_date) : Date::Utility->new()->_minus_months(6);
    $to_date   = $to_date ? Date::Utility->new($to_date) : Date::Utility->new();
    $from_date = Date::Utility->new($from_date->date_yyyymmdd() . " 00:00:00");
    $to_date   = Date::Utility->new($to_date->date_yyyymmdd() . " 23:59:59");
} catch {
    code_exit_BO('Error: Wrong date entered.');
}

my $broker;
if ($loginid =~ /^([A-Z]+)/) {
    $broker = $1;
}
BrokerPresentation($encoded_loginid . '  TRANSFER HISTORY', '', '');
unless ($broker) {
    code_exit_BO("Error: Wrong Login ID $encoded_loginid");
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid, db_operation => 'backoffice_replica'}) };

if (not $client) {
    code_exit_BO("Error: Wrong Login ID ($encoded_loginid).");
}

my $loginid_bar = $loginid;
my $pa          = $client->payment_agent;
Bar($loginid_bar);
print "<span class='error'>PAYMENT AGENT</span>" if ($pa and $pa->is_authenticated);

my $tel          = $client->phone;
my $citizen      = Locale::Country::code2country($client->citizen);
my $residence    = Locale::Country::code2country($client->residence);
my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
my $client_email = $client->email;

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement_internal_transfer_header.html.tt',
    {
        summary_ranges => {
            from => $from_date->date_yyyymmdd(),
            to   => $to_date->date_yyyymmdd()
        },
        currency      => $client->currency,
        loginid       => $client->loginid,
        broker        => $broker,
        from_date     => $from_date->date_yyyymmdd(),
        to_date       => $to_date->date_yyyymmdd(),
        transfer_type => $transfer_type,
        $fellow_account ? (fellow_account => $fellow_account) : (),
        $api_call       ? (api_call       => $api_call)       : (),
        self_post      => request()->url_for('backoffice/f_statement_internal_transfer.cgi'),
        clientedit_url => request()->url_for(
            'backoffice/f_clientloginid_edit.cgi',
            {
                loginID => $client->loginid,
                broker  => $broker
            }
        ),
        statement_url => request()->url_for(
            'backoffice/f_manager_history.cgi',
            {
                loginID => $client->loginid,
                broker  => $broker
            }
        ),
        client => {
            name        => $client_name,
            email       => $client_email,
            country     => $citizen,
            residence   => $residence,
            tel         => $tel,
            date_joined => $client->date_joined,
        },
    },
) || die BOM::Backoffice::Request::template()->error(), "\n";

#  At the moment only payment_agent_transfer supported. In future it can be extended for other payment types.
if ($transfer_type eq 'payment_agent_transfer') {
    my $pa_summary = client_payment_agent_transfer_summary(
        client => $client,
        from   => $from_date->datetime,
        to     => $to_date->datetime
    );

    BOM::Backoffice::Request::template()->process(
        'backoffice/account/statement_summary_payment_agent.html.tt',
        {
            summary_ranges => {
                from => $from_date->date_yyyymmdd(),
                to   => $to_date->date_yyyymmdd()
            },
            currency  => $client->currency,
            self_post => request()->url_for(
                'backoffice/f_statement_internal_transfer.cgi',
                {
                    loginID       => $client->loginid,
                    transfer_type => 'payment_agent_transfer',
                    from_date     => $from_date->date_yyyymmdd(),
                    to_date       => $to_date->date_yyyymmdd(),
                }
            ),
            clientedit_url => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
            summary        => $pa_summary->{sorted}
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    if ($fellow_account) {
        my $fellow_loginid = request()->param('fellow_loginid');
        my $fellow_details = client_payment_agent_transfer_details(
            client         => $client,
            fellow_account => $fellow_account,
            from           => $from_date->datetime,
            to             => $to_date->datetime,
            api_call       => $api_call,
        );

        BOM::Backoffice::Request::template()->process(
            'backoffice/account/statement_payment_agent_details.html.tt',
            {
                currency       => $client->currency,
                clientedit_url => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
                details        => $fellow_details,
                fellow_loginid => $fellow_loginid,
                api_call       => $api_call,
            },
        ) || die BOM::Backoffice::Request::template()->error(), "\n";
    }
}

BarEnd();

code_exit_BO();

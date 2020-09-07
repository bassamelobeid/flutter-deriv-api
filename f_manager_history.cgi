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
use BOM::CTC::Currency;
use BOM::Cryptocurrency::Helper qw(prioritize_address get_crypto_transactions);
BOM::Backoffice::Sysinit::init();

use constant CRYPTO_DEFAULT_TRANSACTION_COUNT => 50;

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
    code_exit_BO("Error: wrong loginID $encoded_loginID");
}

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginID, db_operation => 'replica'}) };

if (not $client) {
    code_exit_BO("Error: wrong loginID ($encoded_loginID) could not get client instance.", $loginID);
}

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});

my $loginid_bar = $loginID;
$loginid_bar .= ' (DEPO & WITH ONLY)' if ($deposit_withdrawal_only);
my $pa = $client->payment_agent;

Bar($loginid_bar);
print "<span style='color:red; font-weight:bold; font-size:14px'>PAYMENT AGENT</span>" if ($pa and $pa->is_authenticated);

# We either choose the dropdown currency from transaction page or use the client currency for quick jump
my $currency         = $client->currency;
my $currency_wrapper = BOM::CTC::Currency->new(
    currency_code => $client->currency,
    broker_code   => $broker,
);
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
        } catch {
            warn "Error caught : $@\n";
            print "<div style='color:red' class='center-aligned'>Error: Unable to fetch total deposits/withdrawals </div>";
        }
    } else {
        print "<div style='color:red' class='center-aligned'>Error: Client $loginID does not have currency set. </div>";
    }
}

# print other untrusted section warning in backoffice
print build_client_warning_message(encode_entities($client->loginid)) . '<br />';

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
my $transactions = get_transactions_details({
        client   => $client,
        currency => $currency,
        from     => (not $all_in_one_page and $from_date) ? $from_date->minus_time_interval('1s')->datetime_yyyymmdd_hhmmss()
        : undef,
        to => (not $all_in_one_page and $to_date) ? $to_date->plus_time_interval('1s')->datetime_yyyymmdd_hhmmss()
        : undef,
        dw_only => $deposit_withdrawal_only,
        limit   => $all_in_one_page ? 99999 : 200,
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

# ========== Crypto Transactions ==========
my $render_crypto_transactions = sub {
    my ($trx_type) = @_;

    return undef unless BOM::Config::CurrencyConfig::is_valid_crypto_currency($currency);

    my $offset_param = "crypto_${trx_type}_offset";
    my $offset       = max(request()->param($offset_param) // 0, 0);
    my $limit        = max(request()->param('limit') // 0, 0) || CRYPTO_DEFAULT_TRANSACTION_COUNT;

    my %params = (
        loginid => $client->loginid,
        limit   => $limit,
        offset  => $offset,
    );
    my @trxns = get_crypto_transactions($broker, $trx_type, %params)->@*;

    my $exchange_rate;
    try {
        $exchange_rate = in_usd(1.0, $currency);
    } catch {
        code_exit_BO("No exchange rate found for currency $currency. Please contact IT.");
    }

    my $transaction_uri = URI->new($currency_wrapper->get_transaction_blockchain_url);
    my $address_uri     = URI->new($currency_wrapper->get_address_blockchain_url);

    my $details_link = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $broker,
            loginID => $client->loginid
        });

    my %fiat           = get_fiat_login_id_for($client->loginid, $broker);
    my %client_details = (
        loginid      => $client->loginid,
        details_link => "$details_link",
        fiat_loginid => $fiat{fiat_loginid},
        fiat_link    => "$fiat{fiat_link}",
    );

    for my $trx (@trxns) {
        $trx->{amount} //= 0;    # it will be undef on newly generated addresses
        $trx->{usd_amount} = formatnumber('amount', 'USD', $trx->{amount} * $exchange_rate);
    }

    my ($prioritize_trx_id, $prioritize_result);
    if ($trx_type eq 'deposit' && $action && $action eq 'prioritize') {
        $prioritize_trx_id = request()->param('db_row_id');
        $prioritize_result = prioritize_address($currency_wrapper, request()->param('prioritize_address'));
    }

    my $make_pagination_url = sub {
        my ($offset_value) = @_;
        return request()->url_for(
            'backoffice/f_manager_history.cgi',
            {
                request()->params->%*,
                $offset_param => max($offset_value, 0),
            })->fragment($trx_type);
    };
    my $prev_url = $offset                 ? $make_pagination_url->($offset - $limit) : undef;
    my $next_url = $limit == scalar @trxns ? $make_pagination_url->($offset + $limit) : undef;

    Bar('CRYPTOCURRENCY ACTIVITY: ' . uc $trx_type);

    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/crypto_cashier/manage_crypto_transactions_cs.tt',
        {
            transactions    => \@trxns,
            broker          => $broker,
            currency        => $currency,
            transaction_uri => $transaction_uri,
            address_uri     => $address_uri,
            testnet         => BOM::Config::on_qa() ? 1 : 0,
            trx_type        => $trx_type,
            pagination      => {
                prev_url => $prev_url,
                next_url => $next_url,
                range    => ($offset + !!@trxns) . ' - ' . ($offset + @trxns),
            },
            prioritize => {
                trx_id => $prioritize_trx_id,
                result => $prioritize_result,
            },
            %client_details,
        }) || die $tt->error();
};

$render_crypto_transactions->($_) for qw(deposit withdrawal);

code_exit_BO();

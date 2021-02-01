#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no indirect;

use Text::Trim qw( trim );
use Locale::Country;
use f_brokerincludeall;
use HTML::Entities;
use List::Util qw( max );
use ExchangeRates::CurrencyConverter qw( in_usd );
use Format::Util::Numbers qw( formatnumber );
use Syntax::Keyword::Try;

use BOM::User::Client;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw( request );
use BOM::Database::ClientDB;
use BOM::Backoffice::Sysinit ();
use BOM::Config;
use BOM::CTC::Currency;
use BOM::Cryptocurrency::Helper qw( reprocess_address get_crypto_transactions );

use constant CRYPTO_DEFAULT_TRANSACTION_COUNT => 50;

BOM::Backoffice::Sysinit::init();
PrintContentType();

my $loginid = uc(request()->param('loginID'));
$loginid =~ s/\s//g;

my $encoded_loginid = encode_entities($loginid);

BrokerPresentation($encoded_loginid . ' CRYPTO HISTORY', '', '');

my $broker = request()->broker_code;

code_exit_BO("Error: wrong login id $encoded_loginid") unless ($broker);

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid, db_operation => 'backoffice_replica'}) };

if (not $client) {
    code_exit_BO("Error: wrong login id ($encoded_loginid) could not get client instance.", $loginid);
}

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});

Bar($loginid);

# We either choose the dropdown currency from transaction page or use the client currency for quick jump
my $currency = $client->currency;
if (my $currency_dropdown = request()->param('currency_dropdown')) {
    $currency = $currency_dropdown unless $currency_dropdown eq 'default';
}

my $currency_wrapper = BOM::CTC::Currency->new(currency_code => $currency);

my $action = request()->param('action');

# print other untrusted section warning in backoffice
print build_client_warning_message(encode_entities($loginid)) . '<br />';

my $client_edit_url = request()->url_for(
    'backoffice/f_clientloginid_edit.cgi',
    {
        loginID => $loginid,
        broker  => $broker
    });

my $client_profit_url = request()->url_for(
    'backoffice/f_profit_check.cgi',
    {
        broker    => $broker,
        loginID   => $loginid,
        startdate => Date::Utility->today()->_minus_months(1)->date,
        enddate   => Date::Utility->today()->date,
    });

my $client_statement_url = request()->url_for(
    'backoffice/f_manager_history.cgi',
    {
        loginID => $loginid,
        broker  => $client->broker,
    });

my $self_url = request()->url_for(
    'backoffice/f_manager_crypto_history.cgi',
    {
        loginID => $loginid,
        broker  => $client->broker,
    });

print "<div style='margin:5px 0;'>"
    . "<input type='button' value='View/edit $loginid Details' onclick='location.href=\"$client_edit_url\"' />"
    . "<input type='button' value='View $loginid Profit' onclick='location.href=\"$client_profit_url\"' />"
    . "<input type='button' value='View $loginid Statement' onclick='location.href=\"$client_statement_url\"' />"
    . "</div>";

my $render_crypto_transactions = sub {
    my ($txn_type) = @_;

    return undef unless BOM::Config::CurrencyConfig::is_valid_crypto_currency($currency);

    my $offset_param = "crypto_${txn_type}_offset";
    my $offset       = max(request()->param($offset_param) // 0, 0);
    my $limit        = max(request()->param('limit') // 0, 0) || CRYPTO_DEFAULT_TRANSACTION_COUNT;
    my $search_param = "${txn_type}_address_search";

    my ($search_address, $search_message);
    if ($action && $action eq $search_param && trim(request()->param($search_param))) {
        $search_address = trim(request()->param($search_param));
        $search_message = "Search result for address: $search_address";
    }

    my %params = (
        loginid        => $client->loginid,
        limit          => $limit,
        offset         => $offset,
        address        => $search_address,
        sort_direction => 'DESC'
    );

    my $exchange_rate;
    try {
        $exchange_rate = in_usd(1.0, $currency);
    } catch {
        code_exit_BO("No exchange rate found for currency $currency. Please contact IT.");
    }

    my @trxns = map {
        my $amount = $_->{amount} //= 0;    # it will be undef on newly generated addresses
        $_->{usd_amount} = formatnumber('amount', 'USD', $amount * $exchange_rate);

        $_
    } get_crypto_transactions($txn_type, %params)->@*;

    my $transaction_uri = URI->new($currency_wrapper->get_transaction_blockchain_url);
    my $address_uri     = URI->new($currency_wrapper->get_address_blockchain_url);

    my $details_link = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $broker,
            loginID => $loginid
        });

    my %fiat           = get_fiat_login_id_for($loginid, $broker);
    my %client_details = (
        loginid      => $loginid,
        details_link => "$details_link",
        fiat_loginid => $fiat{fiat_loginid},
        fiat_link    => "$fiat{fiat_link}",
    );

    my ($trx_id_to_reprocess, $reprocess_result);
    if ($txn_type eq 'deposit' && $action && $action eq 'reprocess_address') {
        $trx_id_to_reprocess = request()->param('db_row_id');
        $reprocess_result    = reprocess_address($currency_wrapper, request()->param('address_to_reprocess'));
    }

    my $make_pagination_url = sub {
        my ($offset_value) = @_;
        return request()->url_for(
            'backoffice/f_manager_history.cgi',
            {
                request()->params->%*,
                $offset_param => max($offset_value, 0),
            })->fragment($txn_type);
    };
    my $prev_url = $offset                 ? $make_pagination_url->($offset - $limit) : undef;
    my $next_url = $limit == scalar @trxns ? $make_pagination_url->($offset + $limit) : undef;

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
            txn_type        => $txn_type,
            search_message  => $search_message,
            pagination      => {
                prev_url => $prev_url,
                next_url => $next_url,
                range    => ($offset + !!@trxns) . ' - ' . ($offset + @trxns),
            },
            reprocess => {
                trx_id => $trx_id_to_reprocess,
                result => $reprocess_result,
            },
            self_url => $self_url,
            %client_details,
        }) || die $tt->error();
};

my $tel              = $client->phone;
my $country          = Locale::Country::code2country($client->citizen) // '';
my $residence        = Locale::Country::code2country($client->residence);
my $client_name      = $client->full_name;
my $client_email     = $client->email;
my $client_joined_at = $client->date_joined;

print "<div style='margin:5px 0;'>"
    . '<table class="hover collapsed" border="1">' . '<tr>'
    . '<th>Login ID</th>'
    . "<td class='copy-on-click'>$loginid</td>"
    . '<th>Name</th>'
    . "<td class='copy-on-click'>$client_name</td>"
    . '<th>Email</th>'
    . "<td class='copy-on-click'>$client_email</td>"
    . '<th>Country</th>'
    . "<td>$country</td>"
    . '<th>Residence</th>'
    . "<td>$residence</td>"
    . '<th>Tel</th>'
    . "<td>$tel</td>"
    . '<th>Date Joined</th>'
    . "<td>$client_joined_at</td>"
    . '</tr></table></div><br/>';

$render_crypto_transactions->($_) for qw(deposit withdrawal);

BarEnd();

print <<QQ;
<script type="text/javascript" language="javascript">
    \$('div.blacklabel.whitelabel.collapsed').click(function(e) {
        e.preventDefault();
        var element = \$(this);
        element.children('span').toggle();
        var content_element = element.siblings('div.contents');
        content_element.toggle();
    });
</script>
QQ

code_exit_BO();


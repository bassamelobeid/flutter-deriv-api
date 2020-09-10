#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::CTC::Currency;
use BOM::Backoffice::Request;
use Syntax::Keyword::Try;
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw(in_usd);

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();
my %input = %{request()->params};
PrintContentType();

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::get_staffname();

BrokerPresentation('CRYPTO TOOL PAGE');

if ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) && !BOM::Config::on_qa()) {
    print "<table border=0 width=97%><tr><td width=97% bgcolor=#FFFFEE>
        <b><center><font size=+1>YOU ARE ON THE MASTER LIVE SERVER</font>
        <br>This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).
        </b></font></td></tr></table>";
}
print "<center>";

my @currency_options  = qw/ BTC LTC ETH UST ERC20/;
my $currency_selected = $input{currency} // 'BTC';

my $tt = BOM::Backoffice::Request::template;
Bar("Select Currency");
$tt->process(
    'backoffice/crypto_admin/currency_selection.html.tt',
    {
        controller_url    => request()->url_for('backoffice/crypto_admin.cgi'),
        currency_options  => \@currency_options,
        currency_selected => $currency_selected
    },
    undef,
    {binmode => ':utf8'});

my $currency_info = _get_currency_info($currency_selected);

$tt->process('backoffice/crypto_admin/general_info.html.tt', {currency_info => $currency_info}, undef, {binmode => ':utf8'});

Bar($currency_selected . " TOOLS");

my $currency_mapper = {
    LTC => 'BTC',
};

$tt->process(
    'backoffice/crypto_admin/' . lc($currency_mapper->{$currency_selected} // $currency_selected) . '_form.html.tt',
    {
        controller_url => request()->url_for('backoffice/crypto_admin.cgi'),
        currency       => $currency_selected,
        cmd            => request()->param('command') // '',
        broker         => $broker,
        staff          => $staff,
    }) || die $tt->error();

if (%input && $input{req_type}) {

    my $req_type = $input{req_type};

    Bar("Results: $req_type");
    code_exit_BO('<p style="color:red"><b>ERROR: Please select ONLY ONE request at a time.</b></p>') if (ref $input{req_type});

    my $currency_wrapper = _get_currency($currency_selected);

    my $func_map = _get_function_map($currency_selected, $currency_wrapper, \%input);

    my $template_details;
    $template_details->{req_type} = $req_type;
    $template_details->{currency} = $currency_selected;
    try {
        my $response = $func_map->{$req_type}();
        $template_details->{response} = $response;
        try {
            $template_details->{response_json} = encode_json($response);
        } catch {
            $template_details->{response_json} = $response;
        }
    } catch {
        $template_details->{response} = +{error => $@};
    };

    BOM::Backoffice::Request::template()
        ->process('backoffice/crypto_admin/' . lc($currency_mapper->{$currency_selected} // $currency_selected) . '_result.html.tt',
        $template_details, undef, {binmode => ':utf8'});

}

sub _get_currency {
    my $currency_selected = shift;
    return BOM::CTC::Currency->new(currency_code => $currency_selected);
}

sub _get_function_map {
    my ($currency_selected, $currency_wrapper, $input) = @_;

    my $address               = length $input->{address}            ? $input->{address}                 : undef;
    my $lu_utxo_address       = length $input->{lu_utxo_address}    ? $input->{lu_utxo_address}         : undef;
    my $confirmations_req     = length $input->{confirmations}      ? int($input->{confirmations})      : undef;
    my $receivedby_minconf    = length $input->{receivedby_minconf} ? int($input->{receivedby_minconf}) : undef;
    my $listtransaction_limit = length $input->{limit}              ? int($input->{limit})              : undef;
    my $esf_confirmation      = length $input->{esf_confirmation}   ? int($input->{esf_confirmation})   : 3;

    code_exit_BO("<p style='color:red'><b>Invalid address</b></p>") if ($address && !$currency_wrapper->is_valid_address($address));

    return +{
        list_unspent_utxo     => sub { $currency_wrapper->get_unspent_transactions($lu_utxo_address ? [$lu_utxo_address] : [], $confirmations_req) },
        get_transaction       => sub { $currency_wrapper->get_transaction_details($input->{txn_id}) },
        get_balance           => sub { $currency_wrapper->get_balance() },
        get_newaddress        => sub { $currency_wrapper->get_new_bo_address() },
        get_estimate_smartfee => sub { $currency_wrapper->get_estimated_fee($esf_confirmation, $input->{esf_estimate_mode}) },
        list_receivedby_address => sub { $currency_wrapper->list_receivedby_address($receivedby_minconf, $input->{address_filter}) },
        get_blockcount          => sub { $currency_wrapper->last_block() },
        get_blockchain_info     => sub { $currency_wrapper->get_info() },
        calculate_withdrawal_fee => sub {
            die "Invalid or missing parameters entered for calculate withdrawal fee"
                unless $input->{withdrawal_address} && $input->{withdrawal_amount};
            $currency_wrapper->get_withdrawal_daemon()->calculate_transaction_fee($input->{withdrawal_address}, $input->{withdrawal_amount});
        },
        }
        if ($currency_selected eq 'BTC' || $currency_selected eq 'LTC');

    return +{
        list_unspent_utxo     => sub { $currency_wrapper->get_unspent_transactions($lu_utxo_address ? [$lu_utxo_address] : [], $confirmations_req) },
        get_newaddress        => sub { $currency_wrapper->get_new_bo_address() },
        get_estimate_smartfee => sub { $currency_wrapper->get_estimated_fee($esf_confirmation, $input->{esf_estimate_mode}) },
        list_receivedby_address => sub { $currency_wrapper->list_receivedby_address($receivedby_minconf, $input->{address_filter}) },
        get_blockcount          => sub { $currency_wrapper->last_block() },
        get_blockchain_info     => sub { $currency_wrapper->get_info() },
        get_wallet_balance      => sub { $currency_wrapper->get_wallet_balance() },
        get_balance             => sub { $address ? $currency_wrapper->get_balance($address) : die "Please enter address"; },
        list_transactions => sub {
            die "Invalid address" if (length $input->{transaction_address} && !$currency_wrapper->is_valid_address($input->{transaction_address}));
            $listtransaction_limit
                ? $currency_wrapper->list_transactions($input->{transaction_address}, $listtransaction_limit)
                : die "Limit must be specified";
        },
        get_transaction => sub {
            die "Transaction hash must be specified" unless length $input->{txn_code};
            die "Transaction hash wrong format" unless length $input->{txn_code} == 64;
            my @res = $currency_wrapper->get_transaction_details($input->{txn_code});
            return \@res;
        },
    } if $currency_selected eq 'UST';

    return +{
        get_balance      => sub { $address ? $currency_wrapper->get_balance($address) : die "Please enter address"; },
        get_accounts     => sub { $currency_wrapper->list_addresses() },
        get_gas_price    => sub { $currency_wrapper->get_info()->{gas_price} },
        get_block_number => sub { $currency_wrapper->get_info()->{last_block} },
        get_syncing      => sub { $currency_wrapper->get_info()->{is_syncing} },
        get_estimatedgas => sub {

            die "Invalid or missing parameters entered for Estimate Gas" unless $input->{to_address} && $input->{amount};

            my $params = {
                from  => $currency_wrapper->account_config->{account}->{address},
                to    => $input->{to_address},
                value => $currency_wrapper->get_blockchain_amount($input->{amount})->as_hex(),
            };

            $currency_wrapper->get_estimatedgas($params);
        },
        get_transactionbyhash => sub {
            die "Please provide transaction_hash" unless length $input->{transaction_hash};
            $currency_wrapper->get_transactionbyhash($input->{transaction_hash});
        },
        get_transaction_receipt => sub {
            die "Transaction hash must be specified" unless length $input->{gtr_transaction_hash};
            $currency_wrapper->get_transaction_receipt($input->{gtr_transaction_hash});
        },
    } if $currency_selected eq 'ETH';

}

sub _get_currency_info {

    my $currency_code = shift;
    my $currency_info;

    my @all_cryptos = LandingCompany::Registry::all_crypto_currencies();

    my @currency_to_get = $currency_code eq 'ERC20' ? grep { _is_erc20($_) } @all_cryptos : $currency_code;

    foreach my $cur (@currency_to_get) {

        my $currency = _get_currency($cur);

        $currency_info->{$cur} = {
            main_address    => $currency->account_config->{account}->{address},
            exchange_rate   => eval { in_usd(1.0, $cur) } // 'Not Specified',
            sweep_limit_max => $currency->config->{sweep}{max_transfer},
            sweep_limit_min => $currency->config->{sweep}{min_transfer},
        };
    }

    return $currency_info;
}

sub _is_erc20 {

    my $currency_code = shift;

    my $currency = _get_currency($currency_code);

    my $parent_currency = $currency->parent_currency() // '';

    return 1 if $parent_currency eq 'ETH';

    return 0;
}

code_exit_BO();

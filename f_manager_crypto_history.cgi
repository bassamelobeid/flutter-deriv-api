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
use BOM::Backoffice::Sysinit ();
use BOM::Config;
use BOM::CTC::Currency;
use BOM::Cryptocurrency::Helper qw( reprocess_address get_crypto_transactions );

use constant CRYPTO_DEFAULT_TRANSACTION_COUNT => 50;

BOM::Backoffice::Sysinit::init();
PrintContentType();

my $broker  = request()->broker_code;
my $loginid = uc(request()->param('loginID') // '');
my $address = request()->param('address');
my $action  = request()->param('action') // '';

unless ($loginid || $address) {
    BrokerPresentation('Crypto History');
    code_exit_BO('Please provide either "loginID" or crypto "address".');
}

$loginid =~ s/\s//g;
my $encoded_loginid = encode_entities($loginid);
BrokerPresentation($loginid ? "$encoded_loginid Crypto History" : "$address Address History");

my $tt = BOM::Backoffice::Request::template;
my ($client_currency, $currencies_info);

my $get_client_edit_url      = get_url_factory('f_clientloginid_edit',     $broker);
my $get_statement_url        = get_url_factory('f_manager_history',        $broker);
my $get_crypto_statement_url = get_url_factory('f_manager_crypto_history', $broker);
my $get_profit_url           = get_url_factory(
    'f_profit_check',
    $broker,
    {
        startdate => Date::Utility->today()->_minus_months(1)->date,
        enddate   => Date::Utility->today()->date,
    });

my $get_currency_info = sub {
    my ($currency_code) = @_;

    my $info = $currencies_info->{$currency_code};

    unless ($info) {
        $info->{wrapper}         = BOM::CTC::Currency->new(currency_code => $currency_code);
        $info->{address_url}     = $info->{wrapper}->get_address_blockchain_url;
        $info->{transaction_url} = $info->{wrapper}->get_transaction_blockchain_url;
        $info->{exchange_rate}   = eval { in_usd(1.0, $currency_code) };
    }

    return $info;
};

my $render_client_info = sub {
    return undef unless $loginid;

    code_exit_BO("Error: wrong login id $encoded_loginid") unless ($broker);

    my $client = eval { BOM::User::Client::get_instance({loginid => $loginid, db_operation => 'backoffice_replica'}) };

    if (not $client) {
        code_exit_BO("Error: wrong login id ($encoded_loginid) could not get client instance.", $loginid);
    }

    Bar($loginid);

    # We either choose the dropdown currency from transaction page or use the client currency for quick jump
    $client_currency = $client->currency;
    if (my $currency_dropdown = request()->param('currency_dropdown')) {
        $client_currency = $currency_dropdown unless $currency_dropdown eq 'default';
    }

    # print other untrusted section warning in backoffice
    print build_client_warning_message(encode_entities($loginid));

    $tt->process(
        'backoffice/common/client_quick_links.html.tt',
        {
            loginid        => $loginid,
            clientedit_url => $get_client_edit_url->($loginid),
            statement_url  => $get_statement_url->($loginid),
            profit_url     => $get_profit_url->($loginid),
        }) || die $tt->error();

    $tt->process(
        'backoffice/common/client_info_brief.html.tt',
        {
            loginid => $loginid,
            client  => {
                name        => $client->full_name,
                email       => $client->email,
                country     => Locale::Country::code2country($client->citizen) // '',
                residence   => Locale::Country::code2country($client->residence),
                tel         => $client->phone,
                date_joined => $client->date_joined,
            },
        }) || die $tt->error();

    BarEnd();
};

my $render_crypto_transactions = sub {
    my ($txn_type) = @_;

    return undef if $client_currency && !BOM::Config::CurrencyConfig::is_valid_crypto_currency($client_currency);

    my $offset_param = "crypto_${txn_type}_offset";
    my $offset       = max(request()->param($offset_param) // 0, 0);
    my $limit        = max(request()->param('limit')       // 0, 0) || CRYPTO_DEFAULT_TRANSACTION_COUNT;
    my $search_param = "${txn_type}_address_search";

    my $search_address = $address;
    if ($action eq $search_param && trim(request()->param($search_param))) {
        $search_address = trim(request()->param($search_param));
    }

    my %query_params = (
        ($loginid ? (loginid => $loginid) : ()),
        limit          => $limit,
        offset         => $offset,
        address        => $search_address,
        sort_direction => 'DESC'
    );

    my @trxns = map {
        my $currency_info = $get_currency_info->($_->{currency_code});
        my $amount = $_->{amount} //= 0;    # it will be undef on newly generated addresses
        if ($currency_info->{exchange_rate}) {
            $_->{usd_amount} = formatnumber('amount', 'USD', $amount * $currency_info->{exchange_rate});
        }
        $_->{address_url}     = URI->new($currency_info->{address_url} . $_->{address})            if $_->{address};
        $_->{transaction_url} = URI->new($currency_info->{transaction_url} . $_->{blockchain_txn}) if $_->{blockchain_txn};

        $_
    } get_crypto_transactions($txn_type, %query_params)->@*;

    my %client_details;
    if ($loginid) {
        my %fiat = get_fiat_login_id_for($loginid, $broker);
        %client_details = (
            loginid      => $loginid,
            details_link => $get_client_edit_url->($loginid),
            fiat_loginid => $fiat{fiat_loginid},
            fiat_link    => $fiat{fiat_link},
        );
    }

    my $reprocess_info;
    if ($txn_type eq 'deposit' && $action eq 'reprocess_address') {
        $reprocess_info->{trx_id} = request()->param('trx_id_to_reprocess');
        $reprocess_info->{result} = reprocess_address(
            $get_currency_info->(request()->param('trx_currency_to_reprocess'))->{wrapper},
            request()->param('address_to_reprocess'),
        );
    }

    my $make_pagination_url = sub {
        my ($offset_value) = @_;
        return request()->url_for(
            'backoffice/f_manager_crypto_history.cgi',
            {
                request()->params->%*,
                $offset_param => max($offset_value, 0),
            })->fragment($txn_type);
    };
    my $pagination_info = {
        prev_url => $offset                 ? $make_pagination_url->($offset - $limit) : undef,
        next_url => $limit == scalar @trxns ? $make_pagination_url->($offset + $limit) : undef,
        range    => ($offset + !!@trxns) . ' - ' . ($offset + @trxns),
    };

    my %min_withdrawal_info;
    if ($txn_type eq 'withdrawal') {
        %min_withdrawal_info = (
            minimum_withdrawal_limit => BOM::CTC::Currency->new(currency_code => $client_currency)->get_minimum_withdrawal,
        );
    }

    $tt->process(
        'backoffice/crypto_cashier/manage_crypto_transactions_cs.tt',
        {
            transactions             => \@trxns,
            broker                   => $broker,
            currency                 => $client_currency,
            testnet                  => BOM::Config::on_qa() ? 1 : 0,
            txn_type                 => $txn_type,
            search_address           => $search_address,
            pagination               => $pagination_info,
            reprocess                => $reprocess_info,
            get_clientedit_url       => $get_client_edit_url,
            get_crypto_statement_url => $get_crypto_statement_url,
            get_profit_url           => $get_profit_url,
            %client_details,
            %min_withdrawal_info,
        }) || die $tt->error() . "\n";
};

$render_client_info->();

$render_crypto_transactions->($_) for qw(deposit withdrawal);

code_exit_BO();

=head2 get_url_factory

Creates subroutines to be used for generating different URLs.

Takes the following arguments:

=over 4

=item * C<$page> - Page name to create the URL for. e.g. C<f_cliendloginig_edit>

=item * C<$broker_code> - Current broker code

=item * C<$args> - Additional arguments to be used in URL

=back

Returns a subroutine which takes the loginID and creates the URL accordingly.

=cut

sub get_url_factory {
    my ($page, $broker_code, $args) = @_;

    return sub {
        my ($client_loginid) = @_;
        return request()->url_for(
            "backoffice/$page.cgi",
            {
                loginID => $client_loginid,
                broker  => $broker_code,
                (ref $args eq 'HASH' ? $args->%* : ()),
            },
        );
    }
}

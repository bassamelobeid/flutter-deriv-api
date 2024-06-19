#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
no indirect;

use Text::Trim qw( trim );
use Locale::Country;
use f_brokerincludeall;
use List::Util                       qw( max );
use ExchangeRates::CurrencyConverter qw( in_usd );
use Format::Util::Numbers            qw( formatnumber );

use BOM::User::Client;
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw( request );
use BOM::Backoffice::Sysinit      ();
use BOM::Config;
use BOM::Cryptocurrency::BatchAPI;
use BOM::Cryptocurrency::Helper qw(render_message has_manual_credit);

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
my ($client_currency, $exchange_rates);
my @batch_requests;

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

my $get_exchange_rate = sub {
    my ($currency_code) = @_;

    $exchange_rates->{$currency_code} //= eval { in_usd(1.0, $currency_code) };

    return $exchange_rates->{$currency_code};
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

    code_exit_BO(
        "<p class='error'>Unable to display crypto transactions because the client's currency ($client_currency) is NOT a cryptocurrency.</p>",
        'Error')
        if $client_currency && !BOM::Config::CurrencyConfig::is_valid_crypto_currency($client_currency);

    BarEnd();
};

my $prepare_transaction = sub {
    my ($txn_type) = @_;

    my $offset_param = "crypto_${txn_type}_offset";
    my $offset       = max(request()->param($offset_param) // 0, 0);
    my $limit        = max(request()->param('limit')       // 0, 0) || CRYPTO_DEFAULT_TRANSACTION_COUNT;
    my $search_param = "${txn_type}_address_search";

    my $search_address = $address;

    my $reprocess_info;
    if ($txn_type eq 'deposit' && $action eq 'reprocess_address') {
        $reprocess_info->{trx_id} = request()->param('trx_id_to_reprocess');
        my $address  = request()->param('address_to_reprocess');
        my $currency = request()->param('trx_currency_to_reprocess');
        my $loginid  = request()->param('loginID');

        unless (has_manual_credit($address, $currency, $loginid)) {

            push @batch_requests, {    # Request for reprocess
                id     => 'reprocess',
                action => 'deposit/reprocess',
                body   => {
                    address       => $address,
                    currency_code => $currency,
                },
            };
        } else {

            $reprocess_info->{manual_credit} = 1;
        }

    } elsif ($txn_type eq 'withdrawal' && defined $client_currency) {
        push @batch_requests, {    # Request for minimum withdrawal
            id     => 'min_withdrawal',
            action => 'withdrawal/get_limits',
            body   => {
                currency_code => $client_currency,
            },
        };
    }

    push @batch_requests, {    # Request for transaction list
        id     => $txn_type . '_list',
        action => 'transaction/get_list',
        body   => {
            address        => $search_address,
            limit          => $limit,
            offset         => $offset,
            type           => $txn_type,
            detail_level   => 'full',
            sort_direction => 'DESC',
            ($loginid ? (loginid => $loginid) : ()),
        },
    };

    my $render = sub {
        my ($transaction_list, %info) = @_;

        for my $transaction_info ($transaction_list->@*) {
            if (my $exchange_rate = $get_exchange_rate->($transaction_info->{currency_code})) {
                $transaction_info->{usd_amount} =
                    formatnumber('amount', 'USD', ($transaction_info->{amount} // 0) * ($transaction_info->{exchange_rate} || $exchange_rate));
                $transaction_info->{usd_client_amount} =
                    $txn_type eq 'deposit'
                    ? (
                    formatnumber('amount', 'USD', ($transaction_info->{client_amount} // 0) * ($transaction_info->{exchange_rate} || $exchange_rate)))
                    : 0;
            }
        }

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

        $reprocess_info->{result} =
            render_message(0, 'Sorry, We have credit the client account manually for this address before, please contact crypto team for this case.')
            if ($reprocess_info->{manual_credit});

        $info{reprocess}{message}    //= $info{reprocess}{error}{message} // '';
        $info{reprocess}{is_success} //= 0;
        $reprocess_info->{result} = render_message(@{$info{reprocess}}{qw/ is_success message /}) if ($info{reprocess});

        my $make_pagination_url = sub {
            my ($offset_value) = @_;
            return request()->url_for(
                'backoffice/f_manager_crypto_history.cgi',
                {
                    request()->params->%*,
                    $offset_param => max($offset_value, 0),
                })->fragment($txn_type);
        };
        my $transactions_count = scalar $transaction_list->@*;
        my $pagination_info    = {
            prev_url => $offset                              ? $make_pagination_url->($offset - $limit) : undef,
            next_url => $limit == scalar $transactions_count ? $make_pagination_url->($offset + $limit) : undef,
            range    => ($offset + !!$transactions_count) . ' - ' . ($offset + $transactions_count),
        };

        my %min_withdrawal_info = exists $info{min_withdrawal} ? (minimum_withdrawal_limit => $info{min_withdrawal}) : ();

        $tt->process(
            'backoffice/crypto_cashier/manage_crypto_transactions_cs.tt',
            {
                transactions             => $transaction_list,
                currency                 => $client_currency,
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

    return $render;
};

$render_client_info->();

my @transaction_types = qw(deposit withdrawal);
my %render_subs       = map { $_ => $prepare_transaction->($_) } @transaction_types;

if (@batch_requests) {
    my $batch = BOM::Cryptocurrency::BatchAPI->new();
    $batch->add_request($_->%*) for @batch_requests;
    $batch->process();

    my $response_bodies  = $batch->get_response_body();
    my %reprocess_result = ($response_bodies->{reprocess} ? (reprocess => $response_bodies->{reprocess}) : ());

    $render_subs{$_}->(
        $response_bodies->{$_ . '_list'}{transaction_list},
        (
              $_ eq 'deposit'
            ? %reprocess_result
            : (min_withdrawal => $response_bodies->{min_withdrawal}{minimum_amount})
        ),
    ) for @transaction_types;
}

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

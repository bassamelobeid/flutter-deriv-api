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
use BOM::CTC::Database;
use BOM::CTC::Script::Address;
use BOM::Backoffice::Request;
use Syntax::Keyword::Try;
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Config::Redis;
use Math::BigFloat;

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use constant REVERT_ERROR_TXN_RECORD => "CRYPTO::ERROR::TXN::ID::";
use constant BUMP_TXN_RECORD         => "CRYPTO::BUMP::TXN::ID::";

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();
my %input = %{request()->params};
PrintContentType();

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::get_staffname();

BrokerPresentation('CRYPTO TOOL PAGE');

if ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) && !BOM::Config::on_qa()) {
    print "<div class='notify notify--warning center'>
            <h3>YOU ARE ON THE MASTER LIVE SERVER</h3>
            <span>This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).</span>
        </div>";
}

my @all_cryptos              = LandingCompany::Registry::all_crypto_currencies();
my @category_options         = ((sort grep { !_is_erc20($_) } @all_cryptos), 'ERC20');
my $currency_selected        = $input{currency} // $input{gt_currency} // 'BTC';
my $category_selected        = _is_erc20($currency_selected) ? 'ERC20' : $currency_selected;
my $controller_url           = request()->url_for('backoffice/crypto_admin.cgi') . '#results';
my $template_currency_mapper = {
    LTC => 'BTC',
};
my $crypto_db_helper = BOM::CTC::Database->new();

my $tt = BOM::Backoffice::Request::template;

Bar("GENERAL TOOLS");
$tt->process(
    'backoffice/crypto_admin/general_crypto_tools.html.tt',
    {
        controller_url    => $controller_url,
        currency_options  => \@all_cryptos,
        currency_selected => $currency_selected,
    },
    undef,
    {binmode => ':utf8'});

Bar($currency_selected . " TOOLS");
$tt->process(
    'backoffice/crypto_admin/general_info.html.tt',
    {
        controller_url    => $controller_url,
        category_options  => \@category_options,
        category_selected => $category_selected,
        currency_info     => _get_currency_info($currency_selected, @all_cryptos),
        currency_selected => $currency_selected,
    },
    undef,
    {binmode => ':utf8'});

$tt->process(
    'backoffice/crypto_admin/function_forms.html.tt',
    {
        controller_url  => $controller_url,
        currency        => $currency_selected,
        form_type       => $template_currency_mapper->{$category_selected} // $category_selected,
        previous_values => \%input,
        previous_req    => $input{req_type} // '',
        cmd             => $input{command}  // '',
        broker          => $broker,
        staff           => $staff,
    }) || die $tt->error();

if (%input && $input{req_type}) {
    my $req_type  = $input{req_type};
    my $req_title = $input{req_title} || $req_type;

    my $is_general_req = $req_type =~ /^gt_/ ? 1 : 0;

    print '<a name="results"></a>';
    Bar("$currency_selected Results: $req_title");
    code_exit_BO('<p class="error">ERROR: Please select ONLY ONE request at a time.</p>') if (ref $input{req_type});

    if ($is_general_req) {
        my $redis_write = BOM::Config::Redis::redis_replicated_write();
        my $redis_read  = BOM::Config::Redis::redis_replicated_read();

        if ($req_type eq 'gt_get_error_txn') {
            my $error_withdrawals = $crypto_db_helper->get_withdrawal_error_txn($input{gt_currency});

            foreach my $txn_record (keys %$error_withdrawals) {
                my $approver = $redis_read->get(REVERT_ERROR_TXN_RECORD . $txn_record);
                $error_withdrawals->{$txn_record}->{approved_by} = $approver;
            }

            $tt->process(
                'backoffice/crypto_admin/error_withdrawals.html.tt',
                {
                    controller_url    => $controller_url,
                    currency          => $input{gt_currency},
                    error_withdrawals => $error_withdrawals,
                }) || die $tt->error();
        }

        if ($req_type eq 'gt_revert_processing_txn') {
            code_exit_BO("No transaction selected")                           unless $input{txn_checkbox};
            code_exit_BO("ERROR: Missing variable staff name. Please check!") unless $staff;
            my %messages;

            my @txn_to_process = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});

            my %h_txn_to_process = map { $_ => $redis_read->get(REVERT_ERROR_TXN_RECORD . $_) } @txn_to_process;
            #gather txn already approved by caller previously or first time
            for (sort { $a <=> $b } @txn_to_process) {
                if (!$h_txn_to_process{$_}) {
                    push @{$messages{
                            "<p class='success'>Following transaction(s) has been successfully approved. Needs one more approval.<br />%s</p>"}}, $_;
                    $redis_write->setex(REVERT_ERROR_TXN_RECORD . $_, 3600, $staff);
                } elsif ($h_txn_to_process{$_} && $h_txn_to_process{$_} eq $staff) {
                    push @{$messages{"<p class='error'>The following transaction(s) have previously been approved by you.<br />%s</p>"}}, $_;
                    $redis_write->setex(REVERT_ERROR_TXN_RECORD . $_, 3600, $staff);
                }
            }

            my $txid_approver_mapping = [];
            #preparing txn list already approved by other staff to send it to db for approval.
            #making array of hash like {id=>123, approver => "approverName"}
            for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
                push @{$txid_approver_mapping},
                    {
                    id       => $_ . "",
                    approver => $h_txn_to_process{$_}};
            }

            #approving the list of txn if already aproved previously by other users
            if (scalar $txid_approver_mapping->@*) {
                try {

                    my $reverted_trxns = $crypto_db_helper->revert_txn_status_to_processing($txid_approver_mapping, $input{gt_currency}, $staff);

                    for ($reverted_trxns->@*) {
                        push @{$messages{"<p class='success'>Following transaction(s) has been successfully reverted.<br />%s</p>"}}, $_->{id};
                        $redis_write->del(REVERT_ERROR_TXN_RECORD . $_->{id});
                    }

                    if (scalar $reverted_trxns->@* == 0
                        || (scalar $reverted_trxns->@* && scalar $txid_approver_mapping->@* != scalar $reverted_trxns->@*))
                    {
                        my %to_delete   = map { $_->{id} => 1 } $reverted_trxns->@*;
                        my @failed_txns = map { $_->{id} } grep { !$to_delete{$_->{id}} } $txid_approver_mapping->@*;
                        push @{
                            $messages{
                                      "<p class='error'>The revert of following transaction(s) failed. Error: "
                                    . "Another withdrawal transaction with same address is still being processed, "
                                    . "please wait for the pending transaction to be completed before trying to revert it<br />%s</p>"
                            }
                            },
                            join ",", sort { $a <=> $b } @failed_txns;
                    }

                } catch ($e) {
                    push @{$messages{"<p class='error'>The revert of following transaction(s) failed. Error: $e<br />%s</p>"}},
                        join ",", map { $_->{id} } $txid_approver_mapping->@*;
                }
            }

            print sprintf($_, join ', ', $messages{$_}->@*) for sort { $b =~ /success/ } keys %messages;
        }
    } else {
        my $currency_wrapper = _get_currency($currency_selected);

        my $template_details;
        $template_details->{req_type} = $req_type;
        $template_details->{currency} = $currency_selected;
        try {
            # these are used for currency_specific calls
            my $func_map = _get_function_map($currency_selected, $currency_wrapper, \%input);

            my $response = $func_map->{$req_type}();
            $template_details->{response} = $response;
            try {
                $template_details->{response_json} = encode_json($response);
            } catch ($e) {
                $template_details->{response_json} = $response;
            }
        } catch ($e) {
            $template_details->{response} = +{error => $e};
        };
        BOM::Backoffice::Request::template()
            ->process('backoffice/crypto_admin/result_' . lc($template_currency_mapper->{$currency_selected} // $currency_selected) . '.html.tt',
            $template_details, undef, {binmode => ':utf8'});
    }
}

sub _get_currency {
    my $currency = shift;
    return BOM::CTC::Currency->new(currency_code => $currency);
}

sub _get_function_map {
    my ($currency, $currency_wrapper, $input) = @_;

    my $address = length $input->{address} ? $input->{address} : undef;
    $input->{txn_hash} =~ s/^\s+|\s+$//g if $input->{txn_hash};
    my $txn_hash        = length $input->{txn_hash}        ? $input->{txn_hash}           : undef;
    my $amount          = length $input->{amount}          ? $input->{amount}             : undef;
    my $confirmations   = length $input->{confirmations}   ? int($input->{confirmations}) : undef;
    my $limit           = length $input->{limit}           ? int($input->{limit})         : undef;
    my $max_fee_per_gas = length $input->{max_fee_per_gas} ? $input->{max_fee_per_gas}    : 0;
    my $staff           = BOM::Backoffice::Auth0::get_staffname();

    die "Invalid address" if ($address && !$currency_wrapper->is_valid_address($address));

    my $import_address = sub {
        my $to_currency    = length $input->{to_currency}    ? $input->{to_currency}       : undef;
        my $import_address = length $input->{import_address} ? $input->{import_address}    : undef;
        my $block_number   = length $input->{block_number}   ? int($input->{block_number}) : undef;

        die "Missing parameters entered for import address"
            unless $currency && $to_currency && $import_address && $block_number;

        BOM::CTC::Script::Address::import_address(
            from_currency => $currency,
            to_currency   => $to_currency,
            address       => $import_address,
            block_number  => $block_number,
        );
    };

    return +{
        list_unspent_utxo        => sub { $currency_wrapper->get_unspent_transactions($address ? [$address] : [], $confirmations) },
        get_transaction          => sub { $currency_wrapper->get_transaction_details($txn_hash) },
        get_wallet_balance       => sub { $currency_wrapper->get_wallet_balance()->{balances}->{$currency} },
        get_main_address_balance => sub { $currency_wrapper->get_main_address_balance()->{$currency} },
        get_address_balance      => sub { $address ? $currency_wrapper->get_address_balance($address) : die "Please enter address"; },
        get_estimate_smartfee    => sub { $currency_wrapper->get_estimated_fee() },
        list_receivedby_address  => sub { $currency_wrapper->list_receivedby_address($confirmations, $address) },
        get_block_count          => sub { $currency_wrapper->last_block() },
        get_blockchain_info      => sub { $currency_wrapper->get_info() },
        import_address           => $import_address,
        bump_btc_transaction     => sub {
            return bump_transaction($staff, $currency_wrapper, $txn_hash, undef);
        },
    } if ($currency =~ /^(BTC|LTC)$/);

    return +{
        list_unspent_utxo        => sub { $currency_wrapper->get_unspent_transactions($address ? [$address] : [], $confirmations) },
        get_estimate_smartfee    => sub { $currency_wrapper->get_estimated_fee() },
        list_receivedby_address  => sub { $currency_wrapper->list_receivedby_address($confirmations, $address) },
        get_block_count          => sub { $currency_wrapper->last_block() },
        get_blockchain_info      => sub { $currency_wrapper->get_info() },
        get_wallet_balance       => sub { $currency_wrapper->get_wallet_balance()->{balances} },
        get_main_address_balance => sub { $currency_wrapper->get_main_address_balance() },
        get_address_balance      => sub { $address ? $currency_wrapper->get_address_balance($address) : die "Please enter address"; },
        list_transactions        => sub {
            die "Missing parameters entered for list transactions"
                unless $address && $limit;
            $currency_wrapper->list_transactions($address, $limit);
        },
        get_transaction => sub {
            die "Transaction hash must be specified" unless length $txn_hash;
            die "Transaction hash wrong format"      unless length $txn_hash == 64;
            my @res = $currency_wrapper->get_transaction_details($txn_hash);
            return \@res;
        },
        import_address => $import_address,
    } if $currency eq 'UST';

    return +{
        get_wallet_balance       => sub { $currency_wrapper->get_wallet_balance()->{balances}->{$currency} },
        get_main_address_balance => sub { $currency_wrapper->get_main_address_balance()->{$currency} },
        get_address_balance      => sub { $address ? $currency_wrapper->get_address_balance($address) : die "Please enter address"; },
        get_accounts             => sub { $currency_wrapper->list_addresses() },
        get_gas_price            => sub { $currency_wrapper->get_info()->{gas_price} },
        get_block_count          => sub { $currency_wrapper->get_info()->{last_block} },
        get_syncing              => sub { $currency_wrapper->get_info()->{is_syncing} },
        get_estimatedgas         => sub {
            die "Invalid or missing parameters entered for Estimate Gas"
                unless $address && $amount;

            my $params = {
                from  => $currency_wrapper->account_config->{account}->{address},
                to    => $address,
                value => $currency_wrapper->get_blockchain_amount($amount)->as_hex(),
            };

            my $gas = $currency_wrapper->get_gas_limit($params);
            return Math::BigFloat->from_hex($gas)->bstr;
        },
        get_transaction => sub {
            die "Please provide transaction_hash" unless length $txn_hash;
            $currency_wrapper->get_transaction($txn_hash);
        },
        get_transaction_receipt => sub {
            die "Transaction hash must be specified" unless length $txn_hash;
            $currency_wrapper->get_transaction_receipt($txn_hash);
        },
        bump_eth_transaction => sub {
            my $result = bump_transaction($staff, $currency_wrapper, $txn_hash, $max_fee_per_gas);
            return $result . sprintf(', <b>Max fee per gas(Gwei):</b> %s', $max_fee_per_gas || 'Not provided') if ref($result) ne 'HASH';
            return $result;
        },
    } if $currency eq 'ETH';
}

sub _get_currency_info {
    my ($currency_code, @all_crypto) = @_;

    my @currency_to_get = _is_erc20($currency_code) ? grep { _is_erc20($_) } @all_crypto : $currency_code;

    my $currency_info;
    foreach my $cur (@currency_to_get) {
        my $currency = _get_currency($cur);

        $currency_info->{$cur} = {
            main_address          => $currency->account_config->{account}->{address},
            exchange_rate         => eval { in_usd(1.0, $cur) } // 'Not Specified',
            sweep_limit_max       => $currency->sweep_max_transfer(),
            sweep_limit_min       => $currency->sweep_min_transfer(),
            sweep_reserve_balance => $currency->sweep_reserve_balance(),
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

sub bump_transaction {
    my ($staff, $currency_wrapper, $txn_hash, $max_fee_per_gas) = @_;
    die $currency_wrapper->currency_code . ":Transaction hash must be specified" unless length $txn_hash;

    my $redis_write         = BOM::Config::Redis::redis_replicated_write();
    my $redis_read          = BOM::Config::Redis::redis_replicated_read();
    my $approved_previously = $redis_read->get(BUMP_TXN_RECORD . $txn_hash);
    #bump if its second person's approval
    if ($approved_previously && $approved_previously ne $staff) {
        $redis_write->del(BUMP_TXN_RECORD . $txn_hash);
        return $currency_wrapper->bump_fee_transaction($txn_hash, $max_fee_per_gas);
    }
    my $approval_message =
        !$approved_previously
        ? 'Transaction has been successfully approved for bump.'
        : 'This transaction is already approved by you for bump.';    # $approved_previously eq $staff
    $redis_write->setex(BUMP_TXN_RECORD . $txn_hash, 3600, $staff);

    return sprintf('<p>%s Needs one more approver.</p><b>Transaction hash:</b> %s', $approval_message, $txn_hash);
}

code_exit_BO();

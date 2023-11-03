#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Auth;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request;
use Syntax::Keyword::Try;
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Config::Redis;
use Math::BigFloat;
use BOM::Cryptocurrency::BatchAPI;
use Data::Dump 'pp';

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use constant REVERT_ERROR_TXN_RECORD           => "CRYPTO::ERROR::TXN::ID::";
use constant DEACTIVATE_DEPOSIT_ADDRESS_RECORD => "CRYPTO::DEACTIVATE::TXN::ID::";
use constant BUMP_TXN_RECORD                   => "CRYPTO::BUMP::TXN::ID::";
use constant SENT_ERROR_TXN_RECORD             => "CRYPTO::SENT::ERROR::TXN::HASH::";

# Check if a staff is logged in
BOM::Backoffice::Auth::get_staff();
my %input = %{request()->params};
PrintContentType();

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth::get_staffname();

BrokerPresentation('CRYPTO TOOL PAGE');

if ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) && !BOM::Config::on_qa()) {
    print "<div class='notify notify--warning center'>
            <h3>YOU ARE ON THE MASTER LIVE SERVER</h3>
            <span>This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).</span>
        </div>";
}

my @all_cryptos = LandingCompany::Registry::all_crypto_currencies();
my @batch_requests;

foreach my $currency_code (@all_cryptos) {
    push @batch_requests, {
        id     => 'currency_info_' . $currency_code,
        action => 'config/get_currency_info',
        body   => {
            currency_code => $currency_code,
            keys          => [qw{
                    account_address
                    is_external
                    sweep_max_transfer
                    sweep_min_transfer
                    sweep_reserve_balance
                    parent_currency
                }
            ],
        },
    };
}

our $currencies_info;
my @category_options;
my $category_selected;
my $currency_selected = $input{currency} // $input{gt_currency} // 'BTC';
my $controller_url    = request()->url_for('backoffice/crypto_admin.cgi') . '#results';
our $template_currency_mapper = {
    LTC => 'BTC',
};
my $addresses       = $input{gt_address} // '';
my @addresses_array = split(/[,\s]+/, $addresses);
my $request_type;
my $req_type   = $input{req_type} =~ /^gt_/ ? $input{req_type} : 'not_general_req' if $input{req_type};
my $gt_actions = {
    'deposit_new' => {
        display_name => 'Deactivate deposit address',
        actions      => {
            gt_deactivate_deposit_txn => {
                action      => 'deposit/update_bulk',
                request_id  => 'deactivate_deposit_address',
                update_type => 'deactivate',
            },
            gt_get_reconciliation_txn => {
                action             => 'transaction/get_list',
                approver_redis_key => DEACTIVATE_DEPOSIT_ADDRESS_RECORD,
                request_body       => {
                    type          => 'deposit_new',
                    currency_code => $currency_selected,
                    addresses     => \@addresses_array,
                },
                request_id       => 'get_new_deposit_addressses',
                transaction_type => 'deposit_new',
            },
        }
    },
    'deposit_error' => {
        display_name => 'Resolve failed deposit payment',
        actions      => {
            gt_get_reconciliation_txn => {
                action             => 'transaction/get_list',
                approver_redis_key => REVERT_ERROR_TXN_RECORD,
                request_body       => {
                    type          => 'deposit_error',
                    currency_code => $currency_selected,
                },
                request_id       => 'get_error_transactions',
                transaction_type => 'deposit_error',
            },
            gt_revert_processing_txn => {
                action      => 'deposit/update_bulk',
                request_id  => 'revert_txn_status',
                update_type => 'process',
            },
        }
    },
    'withdrawal_error' => {
        display_name => 'Resolve failed withdrawal payment',
        actions      => {
            gt_get_reconciliation_txn => {
                action             => 'transaction/get_list',
                approver_redis_key => REVERT_ERROR_TXN_RECORD,
                request_body       => {
                    type          => 'withdrawal_error',
                    currency_code => $currency_selected,
                },
                request_id       => 'get_error_transactions',
                transaction_type => 'withdrawal_error',
            },
            gt_revert_processing_txn => {
                action      => 'withdrawal/update_bulk',
                request_id  => 'revert_txn_status',
                update_type => 'process',
            },
            gt_update_error_txn_sent => {
                action     => 'withdrawal/update_bulk',
                request_id => 'update_sent_error_txns',
            },
        }
    },
};
my @tool_options;

for my $key (keys %$gt_actions) {
    push @tool_options, $gt_actions->{$key}{'display_name'};
}
@tool_options = sort @tool_options;

my $tool_selected =
    defined $input{txn_type}
    ? $gt_actions->{$input{txn_type}}{display_name}
    : $input{gt_reconciliation_action};

my $tt = BOM::Backoffice::Request::template;

sub _get_currency_info {
    my ($currency_code, @all_crypto) = @_;

    my @currency_to_get = _is_erc20($currency_code) ? grep { _is_erc20($_) } @all_crypto : $currency_code;

    my $currency_info;
    foreach my $cur (@currency_to_get) {
        my $currency = $currencies_info->{'currency_info_' . $cur};
        $currency_info->{$cur} = {
            is_external           => $currency->{is_external},
            main_address          => $currency->{account_address},
            exchange_rate         => eval { in_usd(1.0, $cur) } // 'Not Specified',
            sweep_limit_max       => $currency->{sweep_max_transfer},
            sweep_limit_min       => $currency->{sweep_min_transfer},
            sweep_reserve_balance => $currency->{sweep_reserve_balance},
        };
    }

    return $currency_info;
}

sub _is_erc20 {
    my $currency_code = shift;

    return 1 if $currency_code eq 'ERC20';

    my $currency_info = $currencies_info->{'currency_info_' . $currency_code};

    my $parent_currency = $currency_info->{parent_currency} // '';

    return 1 if $parent_currency eq 'ETH';

    return 0;
}

$request_type->{gt_get_reconciliation_txn} = sub {
    my $txn_type;

    for my $key (keys %$gt_actions) {
        $txn_type = $key and last if ($gt_actions->{$key}{'display_name'} eq $tool_selected);
    }

    my ($request_id, $request_action, $request_body, $transaction_type, $approver_redis_key) =
        @{$gt_actions->{$txn_type}{actions}{gt_get_reconciliation_txn}}{qw/ request_id action request_body transaction_type approver_redis_key /};

    push @batch_requests,
        {
        id     => $request_id,
        action => $request_action,
        body   => $request_body,
        };
    return sub {
        my ($response_bodies) = @_;
        my $error = _error_handler($response_bodies, $request_id);

        if ($error) {
            $tt->process(
                'backoffice/crypto_admin/error_transactions.html.tt',
                {
                    controller_url => $controller_url,
                    currency       => $currency_selected,
                    error          => $error->{error},
                }) || die $tt->error();
            return;
        }

        my $error_transactions = $response_bodies->{$request_id}{transaction_list};
        my $redis_read         = BOM::Config::Redis::redis_replicated_read();

        foreach my $txn_record (keys %$error_transactions) {
            my $approver = $redis_read->get($approver_redis_key . $txn_record);
            $error_transactions->{$txn_record}->{approved_by} = $approver;
        }

        $tt->process(
            'backoffice/crypto_admin/error_transactions.html.tt',
            {
                controller_url     => $controller_url,
                currency           => $currency_selected,
                error_transactions => $error_transactions,
                transaction_type   => $transaction_type,
            }) || die $tt->error();
    }
};

$request_type->{gt_revert_processing_txn} = sub {
    my $txn_type;

    for my $key (keys %$gt_actions) {
        $txn_type = $key and last if ($gt_actions->{$key}{'display_name'} eq $tool_selected);
    }

    my ($request_id, $request_action, $update_type) =
        @{$gt_actions->{$txn_type}{actions}{gt_revert_processing_txn}}{qw/ request_id action update_type /};

    if ($input{txn_checkbox} && $staff) {
        my $redis_read            = BOM::Config::Redis::redis_replicated_read();
        my @txn_to_process        = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});
        my %h_txn_to_process      = map { $_ => $redis_read->get(REVERT_ERROR_TXN_RECORD . $_) } @txn_to_process;
        my $txid_approver_mapping = [];

        #preparing txn list already approved by other staff to send it to db for approval.
        #making array of hash like {id=>123, approver => "approverName"}
        for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
            push @{$txid_approver_mapping},
                {
                id       => $_ . "",
                approver => $h_txn_to_process{$_},
                };
        }

        #approving the list of txn if already approved previously by other users
        if (scalar $txid_approver_mapping->@*) {
            push @batch_requests,
                {
                id     => $request_id,
                action => $request_action,
                body   => {
                    currency_code    => $currency_selected,
                    update_type      => $update_type,
                    staff_name       => $staff,
                    transaction_list => $txid_approver_mapping,
                },
                };
        }
    }
    return sub {
        code_exit_BO("No transaction selected")                           unless $input{txn_checkbox};
        code_exit_BO("ERROR: Missing variable staff name. Please check!") unless $staff;

        my ($response_bodies) = @_;

        if (exists $response_bodies->{$request_id}{error}) {
            my $error = "";
            $error .= $response_bodies->{$request_id}{error}{message} . "\n" if exists $response_bodies->{$request_id}{error}{message};
            $error .= $response_bodies->{$request_id}{error}{details} . "\n" if exists $response_bodies->{$request_id}{error}{details};
            code_exit_BO("<p class='error'>$error</p>");
        }

        my $redis_write = BOM::Config::Redis::redis_replicated_write();
        my $redis_read  = BOM::Config::Redis::redis_replicated_read();
        my %messages;
        my @txn_to_process   = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});
        my %h_txn_to_process = map { $_ => $redis_read->get(REVERT_ERROR_TXN_RECORD . $_) } @txn_to_process;

        #gather txn already approved by caller previously or first time
        for (sort { $a <=> $b } @txn_to_process) {
            if (!$h_txn_to_process{$_}) {
                push @{$messages{"<p class='success'>Following transaction(s) has been successfully approved. Needs one more approval.<br />%s</p>"}},
                    $_;
                $redis_write->setex(REVERT_ERROR_TXN_RECORD . $_, 3600, $staff);
            } elsif ($h_txn_to_process{$_} && $h_txn_to_process{$_} eq $staff) {
                push @{$messages{"<p class='error'>The following transaction(s) have previously been approved by you.<br />%s</p>"}}, $_;
                $redis_write->setex(REVERT_ERROR_TXN_RECORD . $_, 3600, $staff);
            }
        }

        my $txid_sent_for_revert = [];

        for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
            push @{$txid_sent_for_revert}, {id => $_};
        }

        #approving the list of txn if already aproved previously by other users
        if (scalar $txid_sent_for_revert->@* && $response_bodies->{revert_txn_status}{transaction_list}) {
            my $reverted_trxns = $response_bodies->{revert_txn_status}{transaction_list};

            for ($reverted_trxns->@*) {
                push @{$messages{"<p class='success'>Following transaction(s) has been successfully reverted.<br />%s</p>"}}, $_->{id};
                $redis_write->del(REVERT_ERROR_TXN_RECORD . $_->{id});
            }

            if (scalar $reverted_trxns->@* == 0
                || (scalar $reverted_trxns->@* && scalar $txid_sent_for_revert->@* != scalar $reverted_trxns->@*))
            {
                my %to_delete   = map { $_->{id} => 1 } $reverted_trxns->@*;
                my @failed_txns = map { $_->{id} } grep { !$to_delete{$_->{id}} } $txid_sent_for_revert->@*;
                push @{
                    $messages{
                              "<p class='error'>The revert of following transaction(s) failed. Error: "
                            . "Another transaction with same address is still being processed, "
                            . "please wait for the pending transaction to be completed before trying to revert it<br />%s</p>"
                    }
                    },
                    join ",", sort { $a <=> $b } @failed_txns;
            }
        }
        print sprintf($_, join ', ', $messages{$_}->@*) for sort { $b =~ /success/ } keys %messages;
    }

};

$request_type->{gt_deactivate_deposit_txn} = sub {
    my $txn_type;

    for my $key (keys %$gt_actions) {
        $txn_type = $key and last if ($gt_actions->{$key}{'display_name'} eq $tool_selected);
    }

    my ($request_id, $request_action, $update_type) =
        @{$gt_actions->{$txn_type}{actions}{gt_deactivate_deposit_txn}}{qw/ request_id action update_type /};

    if ($input{txn_checkbox} && $staff) {
        my $redis_read            = BOM::Config::Redis::redis_replicated_read();
        my @txn_to_process        = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});
        my %h_txn_to_process      = map { $_ => $redis_read->get(DEACTIVATE_DEPOSIT_ADDRESS_RECORD . $_) } @txn_to_process;
        my $txid_approver_mapping = [];

        #preparing txn list already approved by other staff to send it to db for approval.
        #making array of hash like {id=>123, approver => "approverName"}
        for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
            push @{$txid_approver_mapping},
                {
                id       => $_ . "",
                approver => $h_txn_to_process{$_},
                };
        }

        #approving the list of txn if already approved previously by other users
        if (scalar $txid_approver_mapping->@*) {
            push @batch_requests,
                {
                id     => $request_id,
                action => $request_action,
                body   => {
                    currency_code    => $currency_selected,
                    update_type      => $update_type,
                    staff_name       => $staff,
                    transaction_list => $txid_approver_mapping,
                },
                };
        }
    }
    return sub {
        code_exit_BO("No transaction selected")                           unless $input{txn_checkbox};
        code_exit_BO("ERROR: Missing variable staff name. Please check!") unless $staff;

        my ($response_bodies) = @_;
        if (exists $response_bodies->{$request_id}{error}) {
            my $error = "";
            $error .= $response_bodies->{$request_id}{error}{message} . "\n" if exists $response_bodies->{$request_id}{error}{message};
            $error .= $response_bodies->{$request_id}{error}{details} . "\n" if exists $response_bodies->{$request_id}{error}{details};
            code_exit_BO("<p class='error'>$error</p>");
        }

        my $redis_write = BOM::Config::Redis::redis_replicated_write();
        my $redis_read  = BOM::Config::Redis::redis_replicated_read();
        my %messages;
        my @txn_to_process   = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});
        my %h_txn_to_process = map { $_ => $redis_read->get(DEACTIVATE_DEPOSIT_ADDRESS_RECORD . $_) } @txn_to_process;

        #gather txn already approved by caller previously or first time
        for (sort { $a <=> $b } @txn_to_process) {
            if (!$h_txn_to_process{$_}) {
                push @{
                    $messages{
                        "<p class='success'>Following deposit address/addresses has been successfully deactivated. Needs one more approval.<br />%s</p>"
                    }
                    },
                    $_;
                $redis_write->setex(DEACTIVATE_DEPOSIT_ADDRESS_RECORD . $_, 3600, $staff);
            } elsif ($h_txn_to_process{$_} && $h_txn_to_process{$_} eq $staff) {
                push @{$messages{"<p class='error'>The following deposit address/addresses have previously been approved by you.<br />%s</p>"}}, $_;
                $redis_write->setex(DEACTIVATE_DEPOSIT_ADDRESS_RECORD . $_, 3600, $staff);
            }
        }

        my $txid_sent_for_deactivate = [];

        for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
            push @{$txid_sent_for_deactivate}, {id => $_};
        }

        #approving the list of txn if already aproved previously by other users
        if (scalar $txid_sent_for_deactivate->@* && $response_bodies->{deactivate_deposit_address}{transaction_list}) {

            my $deactivated_trxns = $response_bodies->{deactivate_deposit_address}{transaction_list};

            for ($deactivated_trxns->@*) {
                push @{$messages{"<p class='success'>Following deposit address/addresses has been successfully deactivated.<br />%s</p>"}}, $_->{id};
                $redis_write->del(DEACTIVATE_DEPOSIT_ADDRESS_RECORD . $_->{id});
            }

            if (scalar $deactivated_trxns->@* == 0
                || (scalar $deactivated_trxns->@* && scalar $txid_sent_for_deactivate->@* != scalar $deactivated_trxns->@*))
            {
                my %to_delete   = map { $_->{id} => 1 } $deactivated_trxns->@*;
                my @failed_txns = map { $_->{id} } grep { !$to_delete{$_->{id}} } $txid_sent_for_deactivate->@*;
                push @{
                    $messages{
                              "<p class='error'>The deactivation of following deposit address/addresses failed. Error: "
                            . "Another transaction with same address is still being processed, "
                            . "please wait for the pending transaction to be completed before trying to deactivate it<br />%s</p>"
                    }
                    },
                    join ",", sort { $a <=> $b } @failed_txns;
            }
        }
        print sprintf($_, join ', ', $messages{$_}->@*) for sort { $b =~ /success/ } keys %messages;
    }

};

$request_type->{gt_update_error_txn_sent} = sub {
    my $txn_type;

    for my $key (keys %$gt_actions) {
        $txn_type = $key and last if ($gt_actions->{$key}{'display_name'} eq $tool_selected);
    }

    my ($request_id, $request_action) =
        @{$gt_actions->{$txn_type}{actions}{gt_update_error_txn_sent}}{qw/ request_id action /};

    if ($input{txn_checkbox} && $input{txn_hash} && $staff) {
        my $redis_read        = BOM::Config::Redis::redis_replicated_read();
        my $previous_approver = $redis_read->get(SENT_ERROR_TXN_RECORD . $input{txn_hash});
        my @txn_to_process    = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});

        # call batch_requests if the txn hash is previously approved by other than the caller & txn_to_process not empty
        if ($previous_approver && $staff ne $previous_approver && @txn_to_process) {
            push @batch_requests,
                {
                id     => $request_id,
                action => $request_action,
                body   => {
                    currency_code    => $currency_selected,
                    update_type      => 'sent',
                    staff_name       => $staff,
                    approver         => $previous_approver,
                    transaction_list => \@txn_to_process,
                    txn_hash         => $input{txn_hash},
                },
                };
        }
    }
    return sub {
        my $txn_hash = $input{txn_hash};
        code_exit_BO("No transaction selected")                           unless $input{txn_checkbox};
        code_exit_BO("Transaction hash not provided")                     unless $txn_hash;
        code_exit_BO("ERROR: Missing variable staff name. Please check!") unless $staff;

        my $redis_write       = BOM::Config::Redis::redis_replicated_write();
        my $redis_read        = BOM::Config::Redis::redis_replicated_read();
        my $previous_approver = $redis_read->get(SENT_ERROR_TXN_RECORD . $txn_hash);
        my @txn_to_process    = ref($input{txn_checkbox}) eq 'ARRAY' ? $input{txn_checkbox}->@* : ($input{txn_checkbox});

        if ($previous_approver && $staff ne $previous_approver) {
            my ($response_bodies) = @_;
            my $req_type = "update_sent_error_txns";
            if (exists $response_bodies->{$request_id}{error}) {
                my $error = "";
                $error .= $response_bodies->{$request_id}{error}{message} . "\n" if exists $response_bodies->{$request_id}{error}{message};
                $error .= $response_bodies->{$request_id}{error}{details} . "\n" if exists $response_bodies->{$request_id}{error}{details};
                code_exit_BO("<p class='error'>$error</p>");
            }

            my $updated_ids = $response_bodies->{$request_id}{transaction_list};
            if ($updated_ids && scalar @{$updated_ids}) {
                my $ids = (join ',', sort $updated_ids->@*) . ' => ' . $txn_hash;
                print sprintf("<p class='success'>Following transaction(s) has been successfully updated.<br />%s</p>", $ids);
            } else {
                my $ids = (join ',', sort @txn_to_process) . ' => ' . $txn_hash;
                print sprintf("<p class='error'>Following transaction(s) could not be updated, possibly already updated.<br />%s</p>", $ids);
            }
            $redis_write->del(SENT_ERROR_TXN_RECORD . $txn_hash);
        } else {
            my $ids = (join ',', sort @txn_to_process) . ' => ' . $txn_hash;
            my $msg =
                $previous_approver && $previous_approver eq $staff
                ? sprintf("<p class='error'>The following transaction(s) has previously been approved by you.<br />%s</p>",                   $ids)
                : sprintf("<p class='success'>Following transaction(s) has been successfully approved. Needs one more approval.<br />%s</p>", $ids);
            print $msg;
            $redis_write->setex(SENT_ERROR_TXN_RECORD . $txn_hash, 3600, $staff);
        }
    }

};

$request_type->{not_general_req} = sub {
    my $template_details;

    $template_details->{req_type} = $input{req_type};
    $template_details->{currency} = $currency_selected;

    my $func_map = _get_function_map($currency_selected, \%input, \@batch_requests, $input{req_type});
    try {
        $func_map->{$input{req_type}}();
    } catch ($e) {
        $template_details->{response} = +{error => $e};
        _render_template($currency_selected, $template_details);
    };
};

sub _get_function_map {
    my ($currency, $input, $batch_requests, $req_type) = @_;

    my $address = length $input->{address} ? $input->{address} : undef;
    $input->{txn_hash} =~ s/^\s+|\s+$//g if $input->{txn_hash};
    my $txn_hash          = length $input->{txn_hash}        ? $input->{txn_hash}           : undef;
    my $amount            = length $input->{amount}          ? $input->{amount}             : undef;
    my $confirmations     = length $input->{confirmations}   ? int($input->{confirmations}) : undef;
    my $limit             = length $input->{limit}           ? int($input->{limit})         : undef;
    my $max_fee_per_gas   = length $input->{max_fee_per_gas} ? $input->{max_fee_per_gas}    : 0;
    my $staff             = BOM::Backoffice::Auth::get_staffname();
    my $currency_selected = $input->{currency} // $input->{gt_currency} // 'BTC';
    my $currency_code     = $currency;

    my $template_details;
    $template_details->{req_type} = $req_type;
    $template_details->{currency} = $currency;

    my $list_unspent_utxo = sub {
        push @$batch_requests,
            {
            id     => 'list_unspent_utxo',
            action => 'wallet/get_unspent_list',
            body   => {
                currency_code     => $currency_code,
                addresses         => $address ? [$address] : [],
                min_confirmations => $confirmations,
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);
            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{unspent_list};
            _response_handler($template_details);
        }
    };

    my $get_transaction = sub {
        unless (length $txn_hash) {
            return sub {
                $template_details->{response} = +{error => "Transaction hash must be specified"};
                _response_handler($template_details);
            }
        }

        if ($currency eq 'UST') {
            unless (length $txn_hash == 64) {
                return sub {
                    $template_details->{response} = +{error => "Transaction hash wrong format"};
                    _response_handler($template_details);
                }
            }
        }

        my @key = $currency eq 'ETH' ? "blockchain_details" : "transaction_details";
        push @$batch_requests,
            {
            id     => 'get_transaction',
            action => 'wallet/get_transaction_details',
            body   => {
                currency_code    => $currency_code,
                transaction_hash => $txn_hash,
                keys             => \@key,
            },
            };

        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            unless ($error) {
                if ($currency_code ne 'UST') {
                    $template_details->{response} = $response_bodies->{$template_details->{req_type}}{$key[0]};
                } else {
                    my @txn_details = $response_bodies->{$template_details->{req_type}}{$key[0]};
                    $template_details->{response} = \@txn_details;
                }
            }

            $template_details->{response} = $error // $template_details->{response};
            _response_handler($template_details);
        }
    };

    my $get_wallet_balance = sub {
        push @$batch_requests,
            {
            id     => 'get_wallet_balance',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{ balance }],
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            unless ($error) {
                my $balance = $response_bodies->{$template_details->{req_type}}{balance}{balances};
                $template_details->{response} = $currency_code ne 'UST' ? $balance->{$currency_code} : $balance;
            }

            $template_details->{response} = $error // $template_details->{response};
            _response_handler($template_details);
        }
    };

    my $get_main_address_balance = sub {
        push @$batch_requests,
            {
            id     => 'get_main_address_balance',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{main_address_balance}],
            },
            };

        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            unless ($error) {
                my $main_address_balance = $response_bodies->{$template_details->{req_type}}{main_address_balance};
                $template_details->{response} = $currency_code ne 'UST' ? $main_address_balance->{$currency_code} : $main_address_balance;
            }

            $template_details->{response} = $error // $template_details->{response};
            _response_handler($template_details);
        }
    };

    my $get_address_balance = sub {
        unless (length $address) {
            return sub {
                $template_details->{response} = +{error => "Please enter address"};
                _response_handler($template_details);
            }
        }

        push @$batch_requests,
            {
            id     => 'get_address_balance',
            action => 'address/get_balance',
            body   => {
                currency_code => $currency_code,
                address       => $address,
            },
            };

        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{balance};
            _response_handler($template_details);
        }
    };

    my $get_estimate_smartfee = sub {
        push @$batch_requests,
            {
            id     => 'get_estimate_smartfee',
            action => 'wallet/get_estimation_info',
            body   => {
                currency_code => $currency_code,
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{fee};
            _response_handler($template_details);
        }
    };

    my $list_receivedby_address = sub {
        push @$batch_requests,
            {
            id     => 'list_receivedby_address',
            action => 'wallet/get_address_list',
            body   => {
                currency_code     => $currency_code,
                min_confirmations => $confirmations,
                address           => $address,
                detail_level      => "full",
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{address_list};
            _response_handler($template_details);
        }
    };

    my $get_block_count = sub {
        push @$batch_requests,
            {
            id     => 'get_block_count',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{ last_block }],
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{last_block};
            _response_handler($template_details);
        }
    };

    my $get_blockchain_info = sub {
        push @$batch_requests,
            {
            id     => 'get_blockchain_info',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{ blockchain }],
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{blockchain};
            _response_handler($template_details);
        }
    };

    my $import_address = sub {
        my $to_currency    = length $input->{to_currency}    ? $input->{to_currency}       : undef;
        my $import_address = length $input->{import_address} ? $input->{import_address}    : undef;
        my $block_number   = length $input->{block_number}   ? int($input->{block_number}) : undef;

        unless ($currency && $to_currency && $import_address && $block_number) {
            return sub {
                $template_details->{response} = +{error => "Missing parameters entered for import address"};
                _response_handler($template_details);
            }
        }

        push @$batch_requests,
            {
            id     => 'import_address',
            action => 'address/import_address',
            body   => {
                currency_from => $currency_selected,
                currency_to   => $to_currency,
                address       => $import_address,
                block_number  => $block_number,
            },
            };

        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            unless ($error) {
                my $passed_steps = $response_bodies->{$template_details->{req_type}}{passed_steps};
                $template_details->{response} = pp($passed_steps) if $passed_steps;
            }

            $template_details->{response} = $error // $template_details->{response};
            _response_handler($template_details);
        }
    };

    my $bump_transaction = sub {

        unless ($txn_hash) {
            return sub {
                $template_details->{response} = +{error => ":Transaction hash must be specified"};
                _response_handler($template_details);
            }
        }

        my $redis_write           = BOM::Config::Redis::redis_replicated_write();
        my $redis_read            = BOM::Config::Redis::redis_replicated_read();
        my @txn_to_process        = ref($txn_hash) eq 'ARRAY' ? $txn_hash->@* : ($txn_hash);
        my %h_txn_to_process      = map { $_ => $redis_read->get(BUMP_TXN_RECORD . $_) } @txn_to_process;
        my $txid_approver_mapping = [];
        my $id                    = $currency eq "ETH" ? "bump_eth_transaction" : "bump_btc_transaction";

        for (grep { $h_txn_to_process{$_} && $h_txn_to_process{$_} ne $staff } @txn_to_process) {
            push @{$txid_approver_mapping}, $_;
        }

        #bump if its second person's approval
        if (scalar $txid_approver_mapping->@*) {
            push @$batch_requests,
                {
                id     => $id,
                action => 'withdrawal/bump_transaction',
                body   => {
                    currency_code    => $currency_code,
                    transaction_list => $txid_approver_mapping,
                    max_fee_per_gas  => $max_fee_per_gas,
                },
                };
            return sub {
                my ($response_bodies) = @_;
                my $req_type          = $id;
                my $error             = _error_handler($response_bodies, $req_type);

                $template_details->{req_type} = $id;
                $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{response};

                _response_handler($template_details);
            }
        }
        return sub {
            my %messages;
            for (@txn_to_process) {
                if (!$h_txn_to_process{$_}) {
                    push @{$messages{
                            "<p class='success'>Following transaction(s) has been successfully approved. Needs one more approval.<br />%s</p>"}}, $_;
                    $redis_write->setex(BUMP_TXN_RECORD . $_, 3600, $staff);
                } elsif ($h_txn_to_process{$_} && $h_txn_to_process{$_} eq $staff) {
                    push @{$messages{"<p class='error'>The following transaction(s) have previously been approved by you.<br />%s</p>"}}, $_;
                    $redis_write->setex(BUMP_TXN_RECORD . $_, 3600, $staff);
                }
            }

            my $result;
            $result .= sprintf($_, join ', ', $messages{$_}->@*) for keys %messages;
            $result .= sprintf(', <b>Max fee per gas(Gwei):</b> %s', $max_fee_per_gas || 'Not provided') if $currency_code eq 'ETH';

            $template_details->{req_type} = $currency eq "ETH" ? "bump_eth_transactions" : "bump_btc_transactions";
            $template_details->{response} = $result;
            _response_handler($template_details);
        };
    };

    my $list_transactions = sub {
        unless ($address && $limit) {
            return sub {
                $template_details->{response} = +{error => "Missing parameters entered for list transactions"};
                _response_handler($template_details);
            }
        }

        push @$batch_requests,
            {
            id     => 'list_transactions',
            action => 'wallet/get_transaction_list',
            body   => {
                currency_code => $currency_code,
                address       => $address,
                count         => $limit,
            },
            };
        return sub {
            my ($response_bodies) = @_;

            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{transaction_list};
            _response_handler($template_details);
        }
    };

    my $get_gas_price = sub {
        push @$batch_requests,
            {
            id     => 'get_gas_price',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{ blockchain }],
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{blockchain}{gas_price};
            _response_handler($template_details);
        }
    };

    my $get_accounts = sub {
        push @$batch_requests,
            {
            id     => 'get_accounts',
            action => 'wallet/get_address_list',
            body   => {
                currency_code => $currency_code,
            },
            };
        return sub {
            my ($response_bodies) = @_;
            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{address_list};
            _response_handler($template_details);
        }
    };

    my $get_syncing = sub {
        push @$batch_requests,
            {
            id     => 'get_syncing',
            action => 'wallet/get_info',
            body   => {
                currency_code => $currency_code,
                keys          => [qw{blockchain}],
            },
            };
        return sub {
            my ($response_bodies) = @_;

            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{blockchain}{is_syncing};
            _response_handler($template_details);
        }
    };

    my $get_transaction_receipt = sub {
        push @$batch_requests,
            {
            id     => 'get_transaction_receipt',
            action => 'wallet/get_transaction_receipt',
            body   => {
                currency_code    => $currency_code,
                transaction_hash => $txn_hash,
            },
            };
        return sub {
            my ($response_bodies) = @_;

            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{transaction_receipt};
            _response_handler($template_details);
        }
    };

    my $get_estimatedgas = sub {
        push @$batch_requests,
            {
            id     => 'get_estimatedgas',
            action => 'wallet/get_estimation_info',
            body   => {
                currency_code => $currency_code,
                address       => $address,
                amount        => $amount,
            },
            };
        return sub {
            my ($response_bodies) = @_;

            my $error = _error_handler($response_bodies, $req_type);

            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{gas};
            _response_handler($template_details);
        }
    };

    my $get_eth_pending_txn = sub {
        push @$batch_requests,
            {
            id     => 'get_eth_pending_txn',
            action => 'wallet/get_pending_list',
            body   => {
                currency_code => $currency_code,
            },
            };
        return sub {
            my ($response_bodies) = @_;

            my $error = _error_handler($response_bodies, $req_type);
            $template_details->{response} = $error // $response_bodies->{$template_details->{req_type}}{pending_list};

            _response_handler($template_details);
        }
    };

    return +{
        list_unspent_utxo        => $list_unspent_utxo,
        get_transaction          => $get_transaction,
        get_wallet_balance       => $get_wallet_balance,
        get_main_address_balance => $get_main_address_balance,
        get_address_balance      => $get_address_balance,
        get_estimate_smartfee    => $get_estimate_smartfee,
        list_receivedby_address  => $list_receivedby_address,
        get_block_count          => $get_block_count,
        get_blockchain_info      => $get_blockchain_info,
        import_address           => $import_address,
        bump_btc_transaction     => $bump_transaction,
        }
        if ($currency =~ /^(BTC|LTC)$/);

    return +{
        list_unspent_utxo        => $list_unspent_utxo,
        get_estimate_smartfee    => $get_estimate_smartfee,
        list_receivedby_address  => $list_receivedby_address,
        get_block_count          => $get_block_count,
        get_blockchain_info      => $get_blockchain_info,
        get_wallet_balance       => $get_wallet_balance,
        get_main_address_balance => $get_main_address_balance,
        get_address_balance      => $get_address_balance,
        list_transactions        => $list_transactions,
        get_transaction          => $get_transaction,
        import_address           => $import_address,
        }
        if $currency eq 'UST';

    return +{
        get_wallet_balance       => $get_wallet_balance,
        get_main_address_balance => $get_main_address_balance,
        get_address_balance      => $get_address_balance,
        get_accounts             => $get_accounts,
        get_gas_price            => $get_gas_price,
        get_block_count          => $get_block_count,
        get_syncing              => $get_syncing,
        get_estimatedgas         => $get_estimatedgas,
        get_transaction          => $get_transaction,
        get_transaction_receipt  => $get_transaction_receipt,
        bump_eth_transactions    => $bump_transaction,
        get_eth_pending_txn      => $get_eth_pending_txn,
        }
        if $currency eq 'ETH';

    return +{
        get_wallet_balance => $get_wallet_balance,
        }
        if $currency eq 'tUSDT';
}

=head2 _error_handler

parses error in response.
Receives the following parameters:

=over 4

=item * C<response_bodies> - hashref (required) containing batch api responses.

=item * C<req_type>  - string (required), id of action sent during processing batch api.

=back

Returns hashref as {error => $error} or undef.

=cut

sub _error_handler {
    my ($response_bodies, $req_type) = @_;
    $req_type = $req_type // "";
    if (exists $response_bodies->{$req_type}{error}) {
        my $error = "";
        $error .= $response_bodies->{$req_type}{error}{message} . "\n" if exists $response_bodies->{$req_type}{error}{message};
        if (exists $response_bodies->{$req_type}{error}{details}) {
            my $details = $response_bodies->{$req_type}{error}{details};
            $error .= pp($details) if $details;
        }
        return {error => $error};
    }
    return undef;
}

=head2 _render_template

renders the template with the provided template details.
Receives the following parameters:

=over 4

=item * C<currency_code> - string (required)

=item * C<details> - hashref (required) template details

=cut

sub _render_template {
    my ($selected_currency, $details) = @_;
    my $currency      = $currencies_info->{'currency_info_' . $selected_currency};
    my $currency_code = lc($template_currency_mapper->{$selected_currency} // $selected_currency);

    $currency_code = 'external' if ($currency->{is_external});

    BOM::Backoffice::Request::template()
        ->process('backoffice/crypto_admin/result_' . $currency_code . '.html.tt', $details, undef, {binmode => ':utf8'});
}

=head2 _response_handler

parses response for functions mapped under _get_function_map sub only for now.
Receives the following parameters:

=over 4

=item * C<template_details> - hashref (required) containing following keys:

=over 4

=item * C<req_type>  - string (required). Post request name and which are mapped under _get_function_map.

=item * C<currency>  - string (required). Currency code.

=back

Parse the input and display the result on result_CURRENCY_CODE.html.tt page.

=back

=cut

sub _response_handler {
    my $template_details = shift;

    my $currency_selected = $template_details->{currency};
    try {
        $template_details->{response_json} = encode_json($template_details->{response});
    } catch ($e) {
        $template_details->{response_json} = $template_details->{response};
    }

    _render_template($currency_selected, $template_details);
}

# ========== Requesting ==========
my $render_action;
$render_action = $request_type->{$req_type}() if $req_type;

my $batch = BOM::Cryptocurrency::BatchAPI->new();
$batch->add_request($_->%*) for @batch_requests;
$batch->process();
my $response_bodies = $batch->get_response_body();
$currencies_info = $response_bodies;

# ========== Rendering ==========

@category_options  = ((sort grep { !_is_erc20($_) } @all_cryptos), 'ERC20');
$category_selected = _is_erc20($currency_selected) ? 'ERC20' : $currency_selected;

Bar("GENERAL TOOLS");
$tt->process(
    'backoffice/crypto_admin/general_crypto_tools.html.tt',
    {
        controller_url    => $controller_url,
        currency_options  => \@all_cryptos,
        currency_selected => $currency_selected,
        tool_options      => \@tool_options,
        tool_selected     => $tool_selected,
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
    my $req_title = (defined $tool_selected and $tool_selected =~ m/deactivate/i) ? "NEW DEPOSIT TRANSACTIONS" : ($input{req_title} || $req_type);

    print '<a name="results"></a>';
    Bar("$currency_selected Results: $req_title");
    code_exit_BO('<p class="error">ERROR: Please select ONLY ONE request at a time.</p>') if (ref $input{req_type});

    $render_action->($response_bodies) if $render_action;

}

code_exit_BO();

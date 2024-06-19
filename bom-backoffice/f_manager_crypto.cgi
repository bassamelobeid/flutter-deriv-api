#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;
no indirect;

use Date::Utility;
use Format::Util::Numbers qw/financialrounding formatnumber commas/;
use HTML::Entities;
use List::UtilsBy                    qw(sort_by extract_by);
use POSIX                            ();
use ExchangeRates::CurrencyConverter qw(in_usd);
use YAML::XS;
use Math::BigFloat;
use Math::BigInt;
use Syntax::Keyword::Try;
use Log::Any qw($log);

use Bitcoin::RPC::Client;
use Ethereum::RPC::Client;
use LandingCompany::Registry;
use Brands;

use f_brokerincludeall;
use BOM::Backoffice::Auth;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::Script::ValidateStaffPaymentLimit;
use BOM::Config;
use BOM::Cryptocurrency::Helper qw(render_message);
use BOM::DualControl;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::User::Client;

use constant CRYPTO_DEFAULT_TRANSACTION_COUNT => 50;
use constant REJECTION_REASONS => {
    low_trade => {
        reason => 'less trade/no trade',
        remark => 'Low trade, ask client for justification and to request a new payout'
    },
    back_to_fiat => {
        reason => 'back to fiat account',
        remark => 'Deposit was done via fiat, the client needs to withdraw via fiat account'
    },
    crypto_low_trade => {
        reason => 'insufficient trade (manual refund to card)',
        remark => 'Low Trade, need to manual refund back to the card, the client needs to confirm the refund'
    },
    authentication_needed => {
        reason => 'authentication needed',
        remark => 'Authentication needed'
    },
    less_trade_back_to_fiat_account => {
        reason => 'less trade, back to fiat account',
        remark => 'Deposit was done via fiat, traded less hence needs to withdraw via fiat'
    },
    default => {
        reason => 'contact CS',
        remark => 'contact CS'
    },
    other => {
        reason => 'other',
        remark => 'others'
    }};

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth::get_staffname();

# Currency is utilised in Deposit and Withdrawal views accordingly
# to distinguish information among supported cryptocurrencies.
my $currency = request()->param('currency') // 'BTC';
# Action is used for transaction verification purposes.
my $action = request()->param('action');
# Address is retrieved from Search view for `Address` option.
my $address = request()->param('address');
# Show new addresses in recon?
my $show_new_addresses = request()->param('include_new') // '';
# view type is a filter option which is used to sort transactions
# based on their status:it might be either pending, verified, rejected,
# processing,performing_blockchain_txn, sent or error.
# Accessible on Withdrawal action only. By default Withdrawal page
# shows `pending` transactions.
my $view_type = request()->param('view_type') // 'pending';
# Currently, the controller renders page according to Deposit,
# Withdrawal and Search actions.
my $view_action = request()->param('view_action') // '';
# if show_all_pendings is true, all pending withdrawal transaction will be listed;
#otherwise, those verified/rejected by the current user will be filtered out.
my $show_all_pendings = request()->param('show_all_pendings');
# show only one step authorised
my $show_one_authorised = request()->param('show_one_authorised');
# show only one step authorised
my $show_priority_withdrawals = request()->param('show_priority_withdrawals');

code_exit_BO("Invalid currency.")
    if $currency !~ /^[a-zA-Z0-9]{2,20}$/;

my $tt = BOM::Backoffice::Request::template;

my (@batch_requests, @errors);

my $exchange_rate = eval { in_usd(1.0, $currency) };
push @errors, "No exchange rate found for currency $currency. Please contact IT."
    unless defined $exchange_rate;

push @batch_requests, {
    id     => 'currency_info',
    action => 'config/get_currency_info',
    body   => {
        currency_code => $currency,
        keys          => [qw{
                account_address
                is_external
                sweep_max_transfer
                sweep_min_transfer
                sweep_reserve_balance
            }
        ],
    },
};

my $pending_withdrawal_amount = request()->param('pending_withdrawal_amount');
my $pending_estimated_fee;
if ($view_action =~ /^(withdrawals|run)$/) {
    push @batch_requests, {    # Request pending total
        id     => 'get_pending',
        action => 'withdrawal/get_pending_total',
        body   => {
            currency_code => $currency,
        },
    };

    push @batch_requests, {    # Request pending total
        id     => 'get_locked_priority_withdrawals',
        action => 'withdrawal/get_locked_priority_withdrawals_count',
        body   => {
            currency_code => $currency,
        },
    };
}

my $start_date = request()->param('start_date');
my $end_date   = request()->param('end_date');
try {
    if ($start_date && $start_date =~ /[0-9]{4}-[0-1][0-9]{1,2}-[0-3][0-9]{1,2}$/) {
        $start_date = Date::Utility->new("$start_date 00:00:00");
    } else {
        $start_date = Date::Utility->today()->truncate_to_month();
    }

    if ($end_date && $end_date =~ /[0-9]{4}-[0-1][0-9]{1,2}-[0-3][0-9]{1,2}$/) {
        $end_date = Date::Utility->new("$end_date 23:59:59");
    } else {
        $end_date = Date::Utility->today();
    }

    if ($end_date->is_before($start_date)) {
        push @errors, 'Invalid dates, the end date must be after the initial date.';
    }

    if (Date::Utility::days_between($end_date, $start_date) > 30) {
        push @errors, 'Cannot accept dates more than 30 days apart. Please edit start and end dates.';
    }
} catch ($e) {
    push @errors, 'Invalid dates, please check the dates and try again.';
}

my $offset               = max(request()->param("offset") // 0, 0);
my $limit                = CRYPTO_DEFAULT_TRANSACTION_COUNT;
my $display_transactions = sub {
    my ($trxns, $update_errors) = @_;
    # Assign USD equivalent value
    for my $trx (@$trxns) {
        $trx->{amount} //= 0;    # it will be undef on newly generated addresses

        $trx->{exchange_rate} = $trx->{exchange_rate} || $exchange_rate;
        $trx->{amount_usd}    = commas(formatnumber('amount', 'USD', ($trx->{amount} // 0) * $trx->{exchange_rate}));

        $trx->{usd_client_amount} =
            $trx->{type} eq 'deposit' ? commas(formatnumber('amount', 'USD', ($trx->{client_amount} // 0) * $trx->{exchange_rate})) : 0;

        if ($trx->{loginid}) {
            $trx->{statement_link} = request()->url_for(
                'backoffice/f_manager_history.cgi',
                {
                    broker  => $broker,
                    loginID => $trx->{loginid},
                });

            $trx->{profit_link} = request()->url_for(
                'backoffice/f_profit_check.cgi',
                {
                    broker    => $broker,
                    loginID   => $trx->{loginid},
                    startdate => Date::Utility->today()->_minus_months(1)->date,
                    enddate   => Date::Utility->today()->date,
                });

            # We should prevent verifying the withdrawal transaction by the payment team
            # if the client withdrawal is locked
            my $client = BOM::User::Client->new({loginid => $trx->{loginid}});
            $trx->{is_withdrawal_locked} =
                ($client->status->withdrawal_locked || $client->status->cashier_locked || $client->status->no_withdrawal_or_trading)
                if $trx->{type} eq 'withdrawal';

            $trx->{client_status} =
                  $client->fully_authenticated      ? 'Fully Authenticated'
                : $client->status->age_verification ? 'Age Verified'
                :                                     'Unauthenticated';
        }
    }

    #sort rejection reasons & grep only required data for template
    my @rejection_reasons_tpl =
        map  { {index => $_, reason => REJECTION_REASONS->{$_}->{reason}} }
        sort { REJECTION_REASONS->{$a}->{reason} cmp REJECTION_REASONS->{$b}->{reason} }
        keys REJECTION_REASONS->%*;
    my $pagination_qs = {
        currency    => $currency,
        view_action => $view_action,
        offset      => max($offset, 0),
        view_type   => $view_type
    };
    if ($view_action eq 'search') {
        $pagination_qs->{search_type}             = request()->param('search_type');
        $pagination_qs->{search_query}            = request()->param('search_query');
        $pagination_qs->{search_transaction_type} = request()->param('search_transaction_type');
    }
    my $make_pagination_url = sub {
        my ($offset_value) = @_;
        $pagination_qs->{offset} = $offset_value;
        return request()->url_for('backoffice/f_manager_crypto.cgi', $pagination_qs)->fragment('transactions');
    };
    my $transactions_count = scalar $trxns->@*;
    my $pagination_info    = {
        prev_url => $offset                              ? $make_pagination_url->($offset - $limit) : undef,
        next_url => $limit == scalar $transactions_count ? $make_pagination_url->($offset + $limit) : undef,
        range    => ($offset + !!$transactions_count) . ' - ' . ($offset + $transactions_count),
    };
    $pagination_qs->{offset} = $offset;
    # Render template page with transactions
    $tt->process(
        'backoffice/crypto_cashier/manage_crypto_transactions.tt',
        {
            transactions              => $trxns,
            broker                    => $broker,
            currency                  => $currency,
            view_action               => $view_action,
            view_type                 => $view_type,
            controller_url            => request()->url_for('backoffice/f_manager_crypto.cgi', $pagination_qs),
            staff                     => $staff,
            show_all_pendings         => $show_all_pendings         // '',
            show_one_authorised       => $show_one_authorised       // '',
            show_priority_withdrawals => $show_priority_withdrawals // '',
            fetch_url                 => request()->url_for('backoffice/fetch_client_details.cgi'),
            rejection_reasons         => \@rejection_reasons_tpl,
            update_errors             => $update_errors,
            pagination                => $pagination_info,
        }) || die $tt->error() . "\n";
};

=head2 actions

Page actions are defined here.
  - The keys of C<$actions> are possible values of C<$view_action>.
  - Each action pushes its request to C<@batch_requests> and returns a subroutine
    which accepts the response body and renders the results.

=cut

my $actions;
$actions->{withdrawals} = sub {
    push @errors, "Invalid address: $address"
        if $address and $address !~ /^[a-zA-Z0-9:?]+$/;
    push @errors, "Invalid action: $action"
        if $action and $action !~ /^[a-zA-Z]{4,15}$/;
    push @errors, "Invalid selection to view type of transactions: $view_type"
        if not $view_type
        or $view_type !~ /^(?:pending|verified|rejected|cancelled|processing|reverting|performing_blockchain_txn|sent|reverted|error)$/;

    my ($update_errors, $reject_email_params);
    if (my ($is_bulk, $trx_action) = ($action || '') =~ /^(bulk|)(Save|Verify|Reject)$/) {
        my @params_list;
        if ($is_bulk) {
            my $selected_transactions = request->param('selected_transactions');
            push @errors, "No withdrawal transaction is selected for <b>Bulk $trx_action</b>."
                unless $selected_transactions;

            try {
                my $bulk_data = decode_json($selected_transactions);
                @params_list = map { +{$bulk_data->{$_}->%*, id => $_} } sort keys $bulk_data->%*;
            } catch {
                push @errors, 'Invalid JSON format for bulk action on withdrawal transactions received. Please contact BE.';
            }
        } else {
            my %params = request()->params->%*;
            @params_list = {%params{qw(id amount remark rejection_reason loginid app_id other_reason amount_usd exchange_rate)}};
        }

        my %actions_map = (
            Save => {
                update_type      => 'remark',
                validation_error => sub { return undef; },
            },
            Verify => {
                update_type      => 'verify',
                validation_error => \&validation_error_verify,
            },
            Reject => {
                update_type      => 'reject',
                validation_error => \&validation_error_reject,
            },
        );

        my @transaction_list;
        for my $transaction_info (@params_list) {
            if (my $error = $actions_map{$trx_action}->{validation_error}->($transaction_info, $currency, $staff)) {
                $update_errors->{$transaction_info->{id}} = $error;
            } else {
                push @transaction_list, {%{$transaction_info}{qw/ id remark rejection_reason client_siblings exchange_rate/}};
                $reject_email_params->{$transaction_info->{id}} = $transaction_info
                    if $trx_action eq 'Reject';
            }
        }

        if (@transaction_list) {
            push @batch_requests, {    # Request update
                id     => 'update',
                action => 'withdrawal/update_bulk',
                body   => {
                    currency_code    => $currency,
                    staff_name       => $staff,
                    update_type      => $actions_map{$trx_action}->{update_type},
                    transaction_list => [@transaction_list],
                },
            };
        }
    }

    push @batch_requests, {    # Request transaction list
        id     => $view_action,
        action => 'transaction/get_list',
        body   => {
            currency_code  => $currency,
            status         => $view_type eq 'pending' ? 'LOCKED' : uc($view_type),
            type           => 'withdrawal',
            detail_level   => 'full',
            offset         => $offset,
            sort_direction => $view_type eq 'pending' ? 'ASC' : 'DESC',
        },
    };

    return sub {
        my ($response_bodies) = @_;

        my $trxns = $response_bodies->{$view_action}{transaction_list};

        if ($show_one_authorised) {
            # Filter one step authorised txn
            @$trxns = extract_by {
                any { $_ } $_->{authorisers}->@*
            }
            @$trxns;
        }

        unless ($show_all_pendings or $view_type ne 'pending') {
            # Filter pending transactions already audited by the current staff
            @$trxns = extract_by {
                not($_->{authorisers} and grep { /^$staff$/ } $_->{authorisers}->@*)
            }
            @$trxns;
        }

        if ($show_priority_withdrawals) {
            # Filter priority withdrawals
            @$trxns = grep { $_->{is_priority} } $trxns->@*;
        }
        if ($view_type eq 'pending') {
            # show LOCKED
            @$trxns = sort { $b->{is_priority} <=> $a->{is_priority} } $trxns->@*;
        }

        for my $update_result (($response_bodies->{update}{transaction_list} // [])->@*) {
            unless ($update_result->{is_success}) {
                $update_errors->{$update_result->{id}} = $update_result->{message};
            }
        }

        Bar('LIST OF TRANSACTIONS - WITHDRAWAL');
        $display_transactions->($trxns, $update_errors);
    };
};

$actions->{deposits} = sub {
    $view_type ||= 'new';
    push @errors, 'Invalid selection to view type of transactions.'
        if $view_type !~ /^(?:new|pending|confirmed|error)$/;

    push @batch_requests, {    # Request transaction list
        id     => $view_action,
        action => 'transaction/get_list',
        body   => {
            currency_code => $currency,
            status        => uc($view_type),
            type          => 'deposit',
            detail_level  => 'full',
            offset        => $offset,
        },
    };

    return sub {
        my ($response_bodies) = @_;

        Bar('LIST OF TRANSACTIONS - DEPOSITS');
        $display_transactions->($response_bodies->{$view_action}{transaction_list});
    };
};

$actions->{search} = sub {
    my $search_type      = request()->param('search_type');
    my $search_query     = request()->param('search_query');
    my $transaction_type = request()->param('search_transaction_type');

    push @errors, 'Invalid type of search request.'
        unless grep { $search_type eq $_ } qw/loginid address search_transaction_type/;

    push @batch_requests, {    # Request transaction lists
        id     => $transaction_type,
        action => 'transaction/get_list',
        body   => {
            currency_code  => $currency,
            $search_type   => $search_query,
            type           => $transaction_type,
            detail_level   => 'full',
            offset         => $offset,
            sort_direction => 'DESC',
        },
    };

    return sub {
        my ($response_bodies) = @_;

        Bar("SEARCH RESULT FOR $search_query");
        my @transaction_list = $response_bodies->{$transaction_type}{transaction_list}->@*;
        $display_transactions->([@transaction_list]);
    };
};

$actions->{reconcil} = sub {
    push @batch_requests, {    # recon request
        id     => $view_action,
        action => 'report/get_recon',
        body   => {
            currency_code => $currency,
            date_start    => $start_date->date_yyyymmdd,
            date_end      => $end_date->date_yyyymmdd,
            include_new   => $show_new_addresses,
        },
    };

    return sub {
        my ($response_bodies) = @_;

        Bar("$currency Reconciliation");
        $tt->process(
            'backoffice/crypto_cashier/reconciliation.tt',
            {
                transactions => $response_bodies->{$view_action}{recon_report},
                filename     => join '-',
                $start_date->date_yyyymmdd, $end_date->date_yyyymmdd, $currency,
            }) || die $tt->error() . "\n";
    };
};

$actions->{run} = sub {
    my $cmd = request()->param('command') // 'getwallet';

    my %commands = (
        getwallet          => 'balance',
        getavailablepayout => 'main_address_balance',
        getinfo            => 'blockchain',
    );

    return sub { render_message(0, 'Invalid ' . $currency . ' command: ' . $cmd); }
        unless $commands{$cmd};

    push @batch_requests, {    # Request wallet info
        id     => $view_action,
        action => 'wallet/get_info',
        body   => {
            currency_code => $currency,
            keys          => [$commands{$cmd}],
        },
    };

    return sub {
        my ($response_bodies) = @_;

        my $command_result = $response_bodies->{$view_action}{$commands{$cmd}};

        if ($cmd eq 'getwallet') {
            # hash slice has been used here to retrieve both values
            my ($get_balance, $creation_time) = @{$command_result}{qw/ balances creation_time /};
            print "<b>Total Balance(s) in Wallet: </b>";
            for my $currency_balance (sort keys %$get_balance) {
                print sprintf("<p>%s : <b>%s</b></p>", $currency_balance, $get_balance->{$currency_balance});
            }
            if ($creation_time) {
                my $dt = Date::Utility->new($creation_time)->datetime_yyyymmdd_hhmmss_TZ;
                print sprintf("<p><b>Last Update:</b> %s</p>", $dt);
            }
        } elsif ($cmd eq 'getavailablepayout') {
            my $main_address_balance = $command_result;

            print "<hr><h3>Available Balance(s) for Payout:</h3>";
            for my $currency_of_balance (sort keys %$main_address_balance) {
                my $balance        = Math::BigFloat->new($main_address_balance->{$currency_of_balance});
                my $remaining_text = '';
                if ($currency_of_balance eq $currency) {
                    my $remaining = $balance->copy->bsub($pending_withdrawal_amount);
                    $remaining_text = sprintf(
                        " (Remaining after <b>payout</b>: <b class='%s'>%s</b>)",
                        $remaining->is_pos ? 'success' : 'error',
                        formatnumber('amount', $currency_of_balance, $remaining->bstr),
                    );
                } else {
                    my $remaining = $balance->copy->bsub($pending_estimated_fee);
                    $remaining_text = sprintf(
                        " (Remaining after <b>total estimated fees</b>: <b class='%s'>%s</b>)",
                        $remaining->is_pos ? 'success' : 'error',
                        formatnumber('amount', $currency_of_balance, $remaining->bstr),
                    );
                }
                print sprintf("<p>%s : <b>%s</b>$remaining_text</p>",
                    $currency_of_balance, formatnumber('amount', $currency_of_balance, $balance->bstr));
            }
            print sprintf(
                "<p>NOTE: The above values calculated on <b>%s</b>. To get new values, please select <b>Get Available Balance for payout</b> from the above Dropdown.",
                Date::Utility->new()->datetime_yyyymmdd_hhmmss);
        } elsif ($cmd eq 'getinfo') {
            my $get_info = $command_result;
            for my $info (sort keys %$get_info) {
                next if ref($get_info->{$info}) =~ /HASH|ARRAY/;
                print sprintf("<p><b>%s:</b><pre>%s</pre></p>", $info, $get_info->{$info});
            }
        }
    }
};

# ========== Requesting ==========
my $render_action;
$render_action = $actions->{$view_action}->()
    if exists $actions->{$view_action} and not @errors;

# No need to check if the `@batch_requests` is not empty here
# since there is always at least one unconditional request for `currency_info`
my $batch = BOM::Cryptocurrency::BatchAPI->new();
$batch->add_request($_->%*) for @batch_requests;
$batch->process();
my $response_bodies = $batch->get_response_body();

if (my $pending_total = $response_bodies->{get_pending}{pending_total}) {
    ($pending_withdrawal_amount, $pending_estimated_fee) = @{$pending_total}{qw/ amount estimated_fee /};
}
my $locked_priority_withdrawals_count = $response_bodies->{get_locked_priority_withdrawals}{locked_priority_withdrawals_count};

# ========== Rendering ==========
Bar("$currency Info");
my $currency_info = $response_bodies->{currency_info};
$tt->process(
    'backoffice/crypto_cashier/crypto_info.html.tt',
    {
        currency              => $currency,
        exchange_rate         => $exchange_rate // 'N.A.',
        is_external           => $currency_info->{is_external},
        main_address          => $currency_info->{account_address},
        sweep_limit_max       => $currency_info->{sweep_max_transfer},
        sweep_limit_min       => $currency_info->{sweep_min_transfer},
        sweep_reserve_balance => $currency_info->{sweep_reserve_balance},
    }) || die $tt->error() . "\n";

Bar("$currency Actions");
my @crypto_currencies =
    map  { {currency => $_, name => LandingCompany::Registry::get_currency_definition($_)->{name}} }
    sort { $a cmp $b }
    grep { $_ ne 'UST' } LandingCompany::Registry::all_crypto_currencies();    # To be replaced by https://app.clickup.com/t/20696747/CRYPTO-399
$tt->process(
    'backoffice/crypto_cashier/crypto_control_panel.html.tt',
    {
        controller_url                    => request()->url_for('backoffice/f_manager_crypto.cgi'),
        currency                          => $currency,
        all_crypto                        => [@crypto_currencies],
        cmd                               => request()->param('command') // '',
        broker                            => $broker,
        start_date                        => $start_date->isa('Date::Utility') ? $start_date->date_yyyymmdd : $start_date,
        end_date                          => $end_date->isa('Date::Utility')   ? $end_date->date_yyyymmdd   : $end_date,
        show_all_pendings                 => $show_all_pendings,
        show_one_authorised               => $show_one_authorised,
        show_priority_withdrawals         => $show_priority_withdrawals,
        pending_withdrawal_amount         => $pending_withdrawal_amount,
        locked_priority_withdrawals_count => $locked_priority_withdrawals_count,
        include_new                       => $show_new_addresses,
        is_external                       => $currency_info->{is_external},
        errors                            => [@errors],
    }) || die $tt->error() . "\n";

$render_action->($response_bodies)
    if defined $render_action;

code_exit_BO();

=head2 validation_error_verify

Validates a verify request.

Returns error if there is an issue, otherwise C<undef>.

=cut

sub validation_error_verify {
    my ($transaction_info, $currency, $staff) = @_;

    my ($id, $loginid, $amount_usd) = @{$transaction_info}{qw/ id loginid amount_usd/};
    my $client = BOM::User::Client->new({loginid => $loginid});

    return "Error in verifying transaction id: $id. The client $loginid withdrawal is locked."
        if $client->status->withdrawal_locked;

    $amount_usd =~ s/,//g;    # remove commas

    my $over_limit = BOM::Backoffice::Script::ValidateStaffPaymentLimit::validate($staff, $amount_usd);
    return "Error in verifying transaction id: $id. " . $over_limit->get_mesg()
        if $over_limit;

    $transaction_info->{client_siblings} = [map { $_->loginid } $client->siblings->@*];

    return undef;
}

=head2 validation_error_reject

Validates a reject request.

Returns error if there is an issue, otherwise C<undef>.

=cut

sub validation_error_reject {
    my ($transaction_info) = @_;

    my $rejection_reason = $transaction_info->{rejection_reason} // '';

    return 'Please select a reason for rejection to notify client'
        unless $rejection_reason;

    return 'Unexpected rejection reason'
        unless defined REJECTION_REASONS->{$rejection_reason};

    $transaction_info->{remark} .=
          $rejection_reason eq 'other'
        ? $transaction_info->{other_reason}
        : "[@{[ REJECTION_REASONS->{$rejection_reason}->{remark} ]}]";

    return undef;
}

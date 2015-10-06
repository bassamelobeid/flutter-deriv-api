package BOM::WebSocketAPI::v2::Accounts;

use strict;
use warnings;

use BOM::Product::ContractFactory;
use BOM::Platform::Runtime;
use BOM::Product::Transaction;

sub statement {
    my ($c, $args) = @_;

    if (BOM::Platform::Runtime->instance->app_config->quants->features->enable_portfolio_autosell) {
        BOM::Product::Transaction::sell_expired_contracts({
            client => $c->stash('client'),
            source => $c->stash('source'),
        });
    }

    my $statement = get_transactions($c, $args);
    return {
        echo_req  => $args,
        msg_type  => 'statement',
        statement => $statement,
    };
}

sub get_transactions {
    my ($c, $args) = @_;

    my $log          = $c->app->log;
    my $acc          = $c->stash('account');
    my $APPS_BY_DBID = $c->config('APPS_BY_DBID') || {};

    # note, there seems to be a big performance penalty associated with the 'description' option..

    my $and_description = $args->{description};

    $args->{sort_by} = 'transaction_time desc';
    $args->{limit}  ||= 100;
    $args->{offset} ||= 0;
    my $dt_fm   = $args->{dt_fm};
    my $dt_to   = $args->{dt_to};
    my $actions = $args->{action_type} || [];

    for ($dt_fm, $dt_to) {
        next unless $_;
        my $dt = eval { DateTime->from_epoch(epoch => $_) }
            || return $c->_fail("date expression [$_] should be a valid epoch value");
        $_ = $dt;
    }

    my $query = [];
    push @$query, action_type => $actions if @$actions;
    push @$query, transaction_time => {ge => $dt_fm} if $dt_fm;
    push @$query, transaction_time => {lt => $dt_to} if $dt_to;
    $args->{query} = $query if @$query;

    $log->debug("transaction query opts are " . $c->dumper($args));

    my $count = 0;
    my @trxs;
    if ($acc) {
        @trxs  = $acc->find_transaction(%$args);    # Rose
        $count = scalar(@trxs);
    }

    my $trxs = [
        map {
            my $trx    = $_;
            my $source = 'default';
            if (my $app_id = $trx->source) {
                $source = $APPS_BY_DBID->{$app_id};
            }
            my $struct = {
                contract_id      => $trx->financial_market_bet_id,
                transaction_time => $trx->transaction_time->epoch,
                amount           => $trx->amount,
                action_type      => $trx->action_type,
                balance_after    => $trx->balance_after,
                transaction_id   => $trx->id,
            };
            if ($and_description) {
                $struct->{description} = '';
                if (my $fmb = $trx->financial_market_bet) {
                    if (my $con = eval { BOM::Product::ContractFactory::produce_contract($fmb->short_code, $acc->currency_code) }) {
                        $struct->{description} = $con->longcode;
                    }
                }
            }
            $struct
        } @trxs
    ];

    return {
        transactions => $trxs,
        count        => $count
    };
}

sub balance {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my @client_balances;
    for my $cl ($client->siblings) {
        next unless $cl->default_account;

        push @client_balances,
            {
            loginid  => $cl->loginid,
            currency => $cl->default_account->currency_code,
            balance  => $cl->default_account->balance,
            };
    }

    return {
        msg_type => 'balance',
        balance  => \@client_balances,
    };
}

1;

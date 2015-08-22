package BOM::WebSocketAPI::Accounts;

use strict;
use warnings;

use BOM::Product::ContractFactory;

sub statement {
    my $statement = get_transactions(@_);
    return {
        msg_type  => 'statement',
        statement => $statement,
    };
}

sub get_transactions {
    my ($c, $args) = @_;

    $args = $args->{statement};

    my $log          = $c->app->log;
    my $acc          = $c->stash('account');
    my $APPS_BY_DBID = $c->config('APPS_BY_DBID') || {};

    # note, there seems to be a big performance penalty associated with the 'description' option..

    my $and_description = $args->{description};

    $args->{sort_by} ||= 'id desc';
    $args->{limit}   ||= 100;
    $args->{offset}  ||= 0;
    my $dt_fm   = $args->{dt_fm};
    my $dt_to   = $args->{dt_to};
    my $actions = $args->{action} || [];

    for ($dt_fm, $dt_to) {
        next unless $_;
        my $dt = eval { DateTime->from_epoch(epoch => $_) }
            || return $c->_fail("date expression [$_] should be a valid epoch value");
        $_ = $dt;
    }

    if (my $yyyymm = $c->req->param('yyyymm')) {
        my ($year, $month) = $yyyymm =~ /^(....)-(..)$/
            or return $c->_fail("parameter yyyymm [$yyyymm] invalid format, need yyyy-mm e.g. 2015-01");
        $dt_fm = DateTime->new(
            year  => $year,
            month => $month,
            day   => 1
        );
        $dt_to = $dt_fm->clone->add(months => 1);
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
                id               => $trx->id,
                transaction_time => $trx->transaction_time->epoch,
                amount           => $trx->amount,
                who              => $trx->staff_loginid,
                contract_id      => $trx->financial_market_bet_id,
                action_type      => $trx->action_type,
                balance_after    => $trx->balance_after,
                source           => $source,
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
        %$args,
        transactions => $trxs,
        count        => $count
    };
}

1;

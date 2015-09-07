package BOM::WebSocketAPI::v2::Offerings;

use strict;
use warnings;

use Try::Tiny;

use Mojo::Base 'BOM::WebSocketAPI::v2::BaseController';

use BOM::Product::Offerings;
use BOM::WebSocketAPI::v2::Symbols;
use BOM::Product::Contract::Offerings;

my @READABLES = qw/market submarket contract_display start_type sentiment expiry_type/;

sub offerings {
    my ($c, $args) = @_;

    return {
        msg_type => 'offerings',
        offerings => query($c, $args),
    };
}

sub query {
    my $c    = shift;
    my $args = shift || $c->req->params->to_hash;    # get args either via @_ (websockets) or as query params (REST)
    my $app  = $c->app;
    my $log  = $app->log;

    my $send_hierarchy = delete $args->{hierarchy} // 1;
    my $send_selectors = delete $args->{selectors} // 1;
    my $send_contracts = delete $args->{contracts} // 0;
    my $also_dumptolog = delete $args->{dumptolog} // 0;

    my $flyby    = BOM::Product::Offerings::get_offerings_flyby;
    my @all_keys = $flyby->all_keys;
    my %all_keys = map { $_ => 1 } @all_keys;

    # special-case: if symbol missing, map any symbol_display field to it.
    if (my $symbol_display = $args->{symbol_display}) {
        $args->{symbol} //= do {
            my $sp = BOM::WebSocketAPI::v2::Symbols::symbol_search($symbol_display);
            $sp ? $sp->{symbol} : $symbol_display;
            }
    }
    # .. and revert to the fieldname in the flyby.
    $args->{underlying_symbol} ||= $args->{symbol} if $args->{symbol};

    my $query = {
        map { $_ => $args->{$_} }
            grep { $all_keys{$_} }
            keys %$args
    };

    # turn these Readable Strings into codified_values.
    # contract_display is special.. its codified value retains embedded spaces not underscores.
    for my $key (@READABLES) {
        exists $query->{$key} || next;
        for ($query->{$key}) {
            s/^(.)/\L$1/;
            $key eq 'contract_display'
                ? s/ (.)/ \L$1/g
                : s/ (.)/_\L$1/g;
        }
    }

    # a silly query seems to be the only way of getting everything..
    $query = {market => undef} unless keys %$query;

    $log->debug($c->dumper(query => $query));

    my $contracts = [$flyby->query($query)];

    my $selectors = {};
    my $hierarchy = [];
    my $markets   = {};
    my %ds_to_sym = ();
    my %sym_to_ds = ();

    for my $contract (@$contracts) {

        my $row = {%$contract};    # takes a manipulatable copy

        # special-case: efficiently generate symbol displayname too; remember mapping in both directions..
        for ($row->{underlying_symbol}) {
            $row->{symbol_display} = $sym_to_ds{$_} ||= do {
                my $sp = BOM::WebSocketAPI::v2::Symbols::symbol_search($_);
                $sp ? $sp->{display_name} : $_;
            };
            $ds_to_sym{$sym_to_ds{$_}} ||= $_;
        }

        # turn these codified_values into Readable Strings..
        for (@READABLES) {
            exists $row->{$_} || next;
            for ($row->{$_}) {
                s/^(.)/\U$1/;
                s/[_ ](.)/ \U$1/g;
            }
        }

        # accumulate stats..
        for (@all_keys) {
            my $val = $row->{$_} // '(n/a)';
            $selectors->{$_}->{$val}++;
        }

        # remove and remember the redundant bits..
        my $mkt = delete $row->{market};
        my $sbm = delete $row->{submarket};
        my $cc  = delete $row->{contract_category};
        my $sym = delete $row->{symbol_display};
        my $ct  = $row->{contract_display};
        delete $row->{exchange_name};
        delete $row->{underlying_symbol};

        # special-case stats: the 'fixed' hierarchies..
        $selectors->{sym_hierarchy}{$mkt}{$sbm}{$sym}++;
        $selectors->{sbm_hierarchy}{$mkt}{$sbm}++;
        $selectors->{ct_hierarchy}{$cc}{$ct}++;

        # put this row into a branch of a tree..
        push @{$markets->{$mkt}->{$sbm}->{$sym}->{$cc}}, $row;
    }

    # expand into the full 'hierarchy' structure..
    for my $mkt (sort keys %$markets) {
        my $sbms = $markets->{$mkt};
        my $L1   = [];
        for my $sbm (sort keys %$sbms) {
            my $syms = $sbms->{$sbm};
            my $L2   = [];
            for my $sym (sort keys %$syms) {
                my $ccs = $syms->{$sym};
                my $L3  = [];
                for my $cc (sort keys %$ccs) {
                    push @$L3,
                        {
                        contract_category => $cc,
                        available         => $ccs->{$cc}};
                }
                push @$L2,
                    {
                    symbol_display => $sym,
                    symbol         => $ds_to_sym{$sym},
                    available      => $L3
                    };
            }
            push @$L1,
                {
                submarket => $sbm,
                available => $L2
                };
        }
        push @$hierarchy,
            {
            market    => $mkt,
            available => $L1
            };
    }

    my $hit_count = @$contracts;

    my $results = {hit_count => $hit_count};
    $results->{offerings} = $hierarchy if $send_hierarchy;
    $results->{selectors} = $selectors if $send_selectors;
    $results->{contracts} = $contracts if $send_contracts;

    return $results if $c->tx->is_websocket;

    # by default, results are logged
    return $c->_pass($results) if $also_dumptolog;

    my $logdata = {hit_count => $hit_count};
    return $c->_pass($results, $logdata);
}

sub trading_times {
    my ($c, $args) = @_;

    my $date = try { Date::Utility->new($args->{trading_times}) } || Date::Utility->new;
    my $tree = BOM::Product::Contract::Offerings->new(date => $date)->decorate_tree(
        markets     => {name => 'name'},
        submarkets  => {name => 'name'},
        underlyings => {
            name   => 'name',
            times  => 'times',
            events => 'events'
        });
    my $trading_times = {};
    for my $mkt (@$tree) {
        my $market = {};
        push @{$trading_times->{markets}}, $market;
        $market->{name} = $mkt->{name};
        for my $sbm (@{$mkt->{submarkets}}) {
            my $submarket = {};
            push @{$market->{submarkets}}, $submarket;
            $submarket->{name} = $sbm->{name};
            for my $ul (@{$sbm->{underlyings}}) {
                push @{$submarket->{symbols}},
                    {
                    name       => $ul->{name},
                    settlement => $ul->{settlement} || '',
                    events     => $ul->{events},
                    times      => $ul->{times},
                    };
            }
        }
    }
    return {
        msg_type      => 'trading_times',
        trading_times => $trading_times,
    };
}

1;


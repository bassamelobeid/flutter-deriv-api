package BOM::Product::Offerings::TradingDuration;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(generate_trading_durations);

use Digest::MD5 qw(md5_hex);
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;
use Finance::Contract::Category;
use BOM::MarketData qw(create_underlying);
use List::UtilsBy qw(sort_by);

=head2 generate_trading_durations

Goes through binary's offerings and summarizes the trading duration.

Returns an array reference of trading durations in the following format:

[{
    market => { name => 'forex', display_name => localize('Forex') },
    submarket => { name => 'minor_pair', display_name => localize('Minor Pair') },
    data => [
        {
         symbols => [
            { name => 'frxAUDJPY', display_name => localize('AUD/JPY') },
            { name => 'frxAUDUSD', display_name => localize('AUD/USD') },
            ... ],
         trade_durations => [
            {
                trade_type => { name => 'rise_fall', display_name => localize('Rise/Fall') },
                durations  => [
                    {name => ticks, display_name => localize('ticks'), min => 1, max => 10 }, ...
                ]
            },
            ...]
        },
        ...
    ],

},
 ...]

=cut

my %cc_display_name = (
    'callput-euro_atm-spot' => {
        name          => 'rise_fall',
        display_name  => 'Rise/Fall',
        display_order => 1,
    },
    'callput-euro_atm-forward' => {
        name          => 'rise_fall_forward',
        display_name  => 'Rise/Fall (Forward Start)',
        display_order => 1.4,
    },
    'callputequal-euro_atm-spot' => {
        name          => 'rise_fall_equal',
        display_name  => 'Rise/Fall Equal',
        display_order => 1.8,
    },
    'callputequal-euro_atm-forward' => {
        name          => 'rise_fall_equal_forward',
        display_name  => 'Rise/Fall Equal (Forward Start)',
        display_order => 2.2,
    },
    'callput-euro_non_atm-spot' => {
        name          => 'higher_lower',
        display_name  => 'Higher/Lower',
        display_order => 2.4,
    },
);

my %min_max_mapper = (
    s_m => [{
            name         => 's',
            display_name => 'Seconds',
            multiplier   => 60
        },
        {
            name         => 'm',
            display_name => 'Minutes',
            multiplier   => 1
        }
    ],
    s_h => [{
            name         => 's',
            display_name => 'Seconds',
            multiplier   => 3600
        },
        {
            name         => 'm',
            display_name => 'Minutes',
            multiplier   => 60
        },
        {
            name         => 'h',
            display_name => 'Hours',
            multiplier   => 1
        }
    ],
    s_s => [{
            name         => 's',
            display_name => 'Seconds',
            multiplier   => 1
        }
    ],
    m_m => [{
            name         => 'm',
            display_name => 'Minutes',
            multiplier   => 1
        }
    ],
    h_h => [{
            name         => 'h',
            display_name => 'Hours',
            multiplier   => 1
        }
    ],
    m_h => [{
            name         => 'm',
            display_name => 'Minutes',
            multiplier   => 60
        },
        {
            name         => 'h',
            display_name => 'Hours',
            multiplier   => 1
        }
    ],
);

my %order = (
    duration => {
        tick     => 1,
        intraday => 2,
        daily    => 3,
    },
    barrier_type => {
        euro_atm     => 10,
        euro_non_atm => 20,
    },
    start_type => {
        spot    => 100,
        forward => 200,
    },
);

sub generate_trading_durations {
    my ($offerings) = @_;

    my @markets = $offerings->values_for_key('market');

    my $fm  = Finance::Asset::Market::Registry->instance;
    my $sub = Finance::Asset::SubMarket::Registry->instance;
    my @trading_durations;
    foreach my $market (sort { $a->display_order <=> $b->display_order } map { $fm->get($_) } @markets) {
        foreach my $submarket (
            sort { $a->display_order <=> $b->display_order }
            map { $sub->get($_) } $offerings->query({market => $market->name}, ['submarket']))
        {
            my %data;
            foreach my $underlying_symbol (
                sort_by { $_ =~ s{([0-9]+)}{sprintf "%-09.09d", $1}ger } $offerings->query({
                        market    => $market->name,
                        submarket => $submarket->name,
                    },
                    ['underlying_symbol']))
            {
                my @offerings_for_symbol = sort { $a->{display_order} <=> $b->{display_order} } map {
                    $_->[0]->{key} = join '-', ($_->[0]->{contract_category}, $_->[0]->{barrier_category}, $_->[0]->{start_type});
                    my $category_order = $cc_display_name{$_->[0]->{key}}->{display_order} // $_->[1]->display_order;
                    $_->[0]->{display_order} =
                        $category_order * 1000 +
                        $order{duration}->{$_->[0]->{expiry_type}} +
                        ($order{barrier_type}->{$_->[0]->{barrier_category}} // 30) +
                        $order{start_type}->{$_->[0]->{start_type}};
                    $_->[0]
                    }
                    map {
                    [$_, Finance::Contract::Category->new($_->{contract_category})]
                    } $offerings->query({underlying_symbol => $underlying_symbol});
                my $id = _get_offerings_id(\@offerings_for_symbol);
                if ($data{$id}) {
                    push @{$data{$id}{symbol}},
                        {
                        name         => $underlying_symbol,
                        display_name => create_underlying($underlying_symbol)->display_name
                        };
                } else {
                    my (%duplicate, %trade_durations);
                    foreach my $offering (@offerings_for_symbol) {
                        my $key = join '-', ($offering->{contract_category}, $offering->{barrier_category}, $offering->{start_type});
                        my $trade_display_name = $cc_display_name{$key}->{display_name} // $offering->{contract_category_display};
                        my $trade_name         = $cc_display_name{$key}->{name}         // $offering->{contract_category};

                        my $dup_key = $key . "-$offering->{expiry_type}";
                        # skip the opposite contract
                        next if exists $duplicate{$dup_key};
                        $duplicate{$dup_key}++;

                        $trade_durations{$trade_name}{order} //= $offering->{display_order};
                        $trade_durations{$trade_name}{trade_type} //= {
                            name         => $trade_name,
                            display_name => $trade_display_name
                        };
                        if ($offering->{expiry_type} eq 'tick') {
                            push @{$trade_durations{$trade_name}{durations}},
                                +{
                                name         => 'ticks',
                                display_name => 'Ticks',
                                min          => $offering->{min_contract_duration} + 0,
                                max          => $offering->{max_contract_duration} + 0
                                };
                        } elsif ($offering->{expiry_type} eq 'daily') {
                            my ($min) = $offering->{min_contract_duration} =~ /^(\d+)d$/;
                            my ($max) = $offering->{max_contract_duration} =~ /^(\d+)d$/;
                            push @{$trade_durations{$trade_name}{durations}},
                                +{
                                name         => 'days',
                                display_name => 'Days',
                                min          => $min + 0,
                                max          => $max + 0,
                                };
                        } elsif ($offering->{expiry_type} eq 'intraday') {
                            my ($min, $min_unit) = $offering->{min_contract_duration} =~ /^(\d+)(s|m|h)$/;
                            my ($max, $max_unit) = $offering->{max_contract_duration} =~ /^(\d+)(s|m|h|d)$/;
                            # just some inconsistency in definition, so fixing it here
                            if ($max_unit eq 'd' and $max == 1) {
                                ($max, $max_unit) = (24, 'h');
                            }
                            my $min_max = $min_unit . '_' . $max_unit;
                            foreach my $type (@{$min_max_mapper{$min_max}}) {
                                push @{$trade_durations{$trade_name}{durations}},
                                    +{
                                    name         => $type->{name},
                                    display_name => $type->{display_name},
                                    min          => ($min_unit eq $type->{name} ? $min : 1) + 0,
                                    max          => ($max * $type->{multiplier}) + 0,
                                    };
                            }
                        } else {
                            die 'Unknown expiry_type ' . $offering->{expiry_type};
                        }
                    }
                    $data{$id} = {
                        symbol => [{
                                name         => $underlying_symbol,
                                display_name => create_underlying($underlying_symbol)->display_name
                            }
                        ],
                        trade_durations => [map { delete $_->{order}; $_ } sort { $a->{order} <=> $b->{order} } values %trade_durations],
                    };
                }
            }
            push @trading_durations,
                +{
                market => {
                    name         => $market->name,
                    display_name => $market->display_name
                },
                submarket => {
                    name         => $submarket->name,
                    display_name => $submarket->display_name
                },
                data => [map { $data{$_} } sort keys %data],
                };
        }
    }

    return \@trading_durations;
}

sub _get_offerings_id {
    my $offerings = shift;

    my $str;
    foreach my $hash (@$offerings) {
        $str .= join('', map { $_ . $hash->{$_} } grep { $_ ne 'underlying_symbol' and $_ ne 'exchange_name' } sort keys %$hash);
    }
    return substr(md5_hex($str), 0, 16);
}

1;

#!/usr/bin/perl

use strict;
use warnings;

use BOM::Database::QuantsConfig;

my %multiplier = (
    global_potential_loss => 2,
    global_realized_loss  => 1,
);

# limits are defined in USD
my @limits = ({
        market       => ['forex'],
        limit_amount => 100000,
    },
    {
        market            => ['forex'],
        underlying_symbol => ['default'],
        limit_amount      => 40000,
    },
    {
        market       => ['synthetic_index'],
        limit_amount => 200000,
    },
    {
        market            => ['synthetic_index'],
        underlying_symbol => ['default'],
        limit_amount      => 75000,
    },
    {
        market       => ['indices'],
        limit_amount => 50000,
    },
    {
        market            => ['indices'],
        underlying_symbol => ['default'],
        limit_amount      => 30000,
    },
    {
        market       => ['commodities'],
        limit_amount => 30000,
    },
    {
        market            => ['commodities'],
        underlying_symbol => ['default'],
        limit_amount      => 10000,
    },
);

my $qc      = BOM::Database::QuantsConfig->new();
my %updated = ();
foreach my $landing_company (keys %{$qc->broker_code_mapper}) {
    my $broker_code = $qc->broker_code_mapper->{$landing_company};
    next if $updated{$broker_code};
    foreach my $limit_type (keys %multiplier) {
        foreach my $limit (@limits) {
            my %config = %$limit;
            $config{landing_company} = [$landing_company];
            $config{limit_type}      = $limit_type;
            my $current_amount = $qc->get_global_limit({
                limit_type => $config{limit_type},
                (map { $_ => $config{$_}->[0] } qw(market underlying_symbol landing_company)),
            });
            my $default_amount = $config{limit_amount} * $multiplier{$limit_type};
            next if defined $current_amount and $current_amount < $default_amount;
            $config{limit_amount} = $default_amount;
            $qc->set_global_limit(\%config);
        }
    }
    $updated{$broker_code}++;
}


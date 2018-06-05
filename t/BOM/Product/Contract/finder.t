#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Test::Deep qw( cmp_deeply );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use BOM::Product::ContractFinder;
use Date::Utility;
use Scalar::Util::Numeric qw(isint);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index',    {symbol => $_}) for qw(AEX SYNAEX frxAUDUSD frxXPDUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxAUDCAD frxXAUUSD frxXPDUSD frxEURUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(AEX FPCS);

my $finder = BOM::Product::ContractFinder->new;

subtest "basic_contracts_for" => sub {
    my %input = (
        random      => ['R_100',     'RDBEAR'],
        forex       => ['frxUSDJPY', 'frxAUDCAD', 'frxEURUSD', 'WLDUSD'],
        indices     => ['AEX',       'SYNAEX'],
        commodities => ['frxXAUUSD', 'frxXPDUSD'],
    );
    my %expected = (
        R_100 => {
            callput      => 14,
            touchnotouch => 6,    # intraday and daily separated
            staysinout   => 4,
            endsinout    => 4,
            digits       => 6,
            asian        => 2,
            reset        => 4,
        },
        RDBEAR => {
            callput      => 10,
            touchnotouch => 2,    # intraday and daily separated
            staysinout   => 2,
            endsinout    => 2,
            digits       => 6,
        },
        frxUSDJPY => {
            callput      => 10,
            touchnotouch => 2,    # only daily
            staysinout   => 2,
            endsinout    => 2,
        },
        frxAUDCAD => {
            callput => 6,
        },
        WLDUSD => {
            callput => 4,
        },
        AEX => {
            callput      => 8,
            touchnotouch => 2,    # only daily
            staysinout   => 2,
            endsinout    => 2,
        },
        FPCS => {
            callput => 8,
        },
        frxXAUUSD => {
            callput      => 8,
            touchnotouch => 2,    # only daily
            staysinout   => 2,
            endsinout    => 2,
        },
        frxXPDUSD => {
            callput => 2,
        },
    );

    my $expected_blackouts = [['11:00:00', '13:00:00'], ['20:00:00', '23:59:59']];

    foreach my $market (keys %input) {
        foreach my $u (@{$input{$market}}) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => $u,
                epoch      => time,
                quote      => 100
            });
            my $f = $finder->basic_contracts_for({symbol => $u});

            if ($u eq 'frxEURUSD') {
                foreach my $contract (@{$f->{'available'}}) {
                    cmp_deeply $contract->{'forward_starting_options'}[0]{'blackouts'}, $expected_blackouts, "expected blackouts"
                        if $contract->{start_type} eq 'forward';
                }
            }

            ok $f->{feed_license}, 'has feed license key available';
            is($f->{feed_license}, 'realtime', 'correct feed license key available') if ($market eq 'volidx');
            my %got;
            $got{$_->{contract_category}}++ for (@{$f->{available}});
            cmp_ok $got{$_}, '==', $expected{$u}{$_}, "expected outcome for $u-$_" for (keys %{$expected{$u}});
        }
    }
};

subtest 'default barrier(s)' => sub {
    note("barriers for AEX");
    my $aex_contracts = $finder->basic_contracts_for({symbol => 'AEX'});
    my @daily_contracts = grep { $_->{expiry_type} eq 'daily' } @{$aex_contracts->{available}};
    foreach my $data (@daily_contracts) {
        ok isint($data->{barrier}),      'barrier is integer'      if $data->{barrier};
        ok isint($data->{high_barrier}), 'high_barrier is integer' if $data->{high_barrier};
        ok isint($data->{low_barrier}),  'low_barrier is integer'  if $data->{low_barrier};
    }

    note("barriers for frxUSDJPY");
    my $usdjpy_contracts = $finder->basic_contracts_for({symbol => 'frxUSDJPY'});
    @daily_contracts = grep { $_->{barriers} > 0 } @{$usdjpy_contracts->{available}};
    foreach my $data (@daily_contracts) {
        ok !isint($data->{barrier}),      'barrier is non integer'      if $data->{barrier};
        ok !isint($data->{high_barrier}), 'high_barrier is non integer' if $data->{high_barrier};
        ok !isint($data->{low_barrier}),  'low_barrier is non integer'  if $data->{low_barrier};
    }
};

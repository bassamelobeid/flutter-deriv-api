#!/usr/bin/perl
package BOM::System::Script::UpdateSmartFxVol;

=head1 NAME

BOM::System::Script::UpdateVol;

=head1 DESCRIPTION

Updates our vols with the latest quotes we have received from Bloomberg.

=cut

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use YAML::CacheLoader;
use List::Util qw(first);
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::MarketData::VolSurface::Flat;

use Date::Utility;

use JSON qw(from_json);

has volatility_spread => (
    is => 'ro',
    default => 0.03,
);

has fx_corr => (
    is => 'ro',
    lazy_build => 1,
);

sub _build_fx_corr {
    return YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom-market/config/files/forex_correlation_matrices.yml');
}

has world_symbols => (
    is => 'ro',
    default => sub {{
        WLDUSD => {
            source => [qw(frxEURUSD frxUSDJPY frxGBPUSD frxUSDCAD frxAUDUSD)],
            negative => [qw(frxGBPUSD frxEURUSD)]},
        WLDAUD => {
            source => [qw(frxAUDCAD frxAUDJPY frxAUDUSD frxEURAUD frxGBPAUD)],
            negative => [qw(frxEURAUD frxGBPAUD)],},
        WLDEUR => {
            source => [qw(frxEURAUD frxEURCAD frxEURGBP frxEURJPY frxEURUSD)],
            negative => [qw()],
            },
        WLDGBP => {
            source => [qw(frxEURGBP frxGBPAUD frxGBPCAD frxGBPJPY frxGBPUSD)],
            negative => [qw(EURGBP)],
        },
    }},
);

sub documentation {
    return 'updates smart fx volatility surfaces.';
}

sub script_run {
    my $self = shift;

    my $world = $self->world_symbols;
    my @smart_symbols = keys %$world;
    foreach my $symbol (@smart_symbols) {
        my %neg = map {$_ => 1} @{$world->{$symbol}->{negative}};
        my $date = Date::Utility->new();
        next if $date->is_a_weekend;
        my @source = map {BOM::Market::Underlying->new($_)} @{$self->world_symbols->{$symbol}->{source}};
        my $surface;
        my %vs = map {$_->symbol => BOM::MarketData::VolSurface::Delta->new({underlying => $_})} @source;
        my @term = sort {$a<=>$b} @{$vs{$source[0]->symbol}->original_term_for_smile};
        my $term = $term[0];
        my $corr_matrix = $self->get_correlation_matrix($symbol);
        next unless $corr_matrix;
        my $chol = cholesky($corr_matrix);
        my ($p1,$p2,$p3,$p4) = map {$$chol[0][$_]} (1..4);
        my ($p5,$p6,$p7,$p8) = map {$$chol[1][$_]} (1..4);
        my ($p9,$p10,$p11) = map {$$chol[2][$_]} (2..4);
        my ($p12,$p13) = map {$$chol[3][$_]} (3,4);
        my $p14 = $$chol[4][4];
        my $smile;
        my $vol = 0.0;
        foreach my $strike (100) {
            my @vols;
            @vols = map {$neg{$_->symbol} ? -$vs{$_->symbol}->get_volatility({moneyness => $strike, days => $term}) : $vs{$_->symbol}->get_volatility({moneyness => $strike, days => $term})} @source;
            my $x1 = $vols[0] + $vols[1]*$p1 + $vols[2]*$p2 + $vols[3]*$p3 + $vols[4]*$p4;
            my $x2 = $vols[1]*$p5 + $vols[2]*$p6 + $vols[3]*$p7 + $vols[4]*$p8;
            my $x3 = $vols[2]*$p9 + $vols[3]*$p10 + $vols[4]*$p11;
            my $x4 = $vols[3]*$p12 + $vols[4]*$p13;
            my $x5 = $vols[4]*$p14;
            my $calc_vol = sqrt(0.04 * ($x1**2+$x2**2+$x3**2+$x4**2+$x5**2));
            $smile->{$strike} = $calc_vol;
            $vol = $calc_vol;
        }
        $surface->{$term} = {
            vol_spread => {100 => $self->volatility_spread},
            smile => $smile,
        };
        my $u      = BOM::Market::Underlying->new($symbol);


        my $v = BOM::MarketData::VolSurface::Flat->new({
                underlying          => $u,
                flat_vol            => $vol,
                flat_atm_spread     => 0,
                surface             => {},
                recorded_date       => $date,
        });
        $v->save;
      }
    return $self->return_value();
}
sub cholesky {
    my $matrix = shift;
    my $chol = [ map { [(0) x @$matrix ] } @$matrix ];
    for my $row (0..@$matrix-1) {
        for my $col (0..$row) {
            my $x = $$matrix[$row][$col];
            $x -= $$chol[$row][$_]*$$chol[$col][$_] for 0..$col;
            $$chol[$row][$col] = $row == $col ? sqrt $x : $x/$$chol[$col][$col];
        }
    }
    return transpose($chol);
}

sub transpose {
    my $matrix = shift;
    my $transposed = [];
    for my $ri (0..4) {
        for my $ci (0..4) {
            my $x = $$matrix[$ri][$ci];
            $$transposed[$ci][$ri] = $x;
        }
    }
    return $transposed;
}

sub get_correlation_matrix {
    my ($self, $which) = @_;

    my @matrix;
    my @source = map {lc} @{$self->world_symbols->{$which}->{source}};
    foreach my $s (@source) {
        my @row;
        foreach my $s1 (@source) {
            my $val;
            if ($s eq $s1) {
                $val = 1;
            } else {
                my $h = $self->fx_corr->{"$s-$s1"} ? $self->fx_corr->{"$s-$s1"} : $self->fx_corr->{"$s1-$s"};
                $val = $h;
            }
            push @row, $val;
        }
        push @matrix, \@row;
    }
    return \@matrix;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
package main;
exit BOM::System::Script::UpdateSmartFxVol->new->run;

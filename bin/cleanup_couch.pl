#!/usr/bin/perl

use strict;
use warnings;

use YAML::XS qw(LoadFile);
use BOM::Market::UnderlyingDB;
use BOM::MarketData::ExchangeConfig;
use Date::Utility;

my @all = ('indices', 'stocks');
my @underlying_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market => \@all,
);

my @exchanges;

foreach my $symbol (@underlying_symbols) {
    my $exchange_symbol = BOM::Market::Underlying->new($symbol)->exchange->symbol;
    my $exchange_data = BOM::MarketData::ExchangeConfig->new({symbol => $exchange_symbol})->get_parameters;
    foreach my $key ('dst', 'standard') {
        if (not $exchange_data->{market_times}->{$key}) { next;}
        my $close = $exchange_data->{market_times}->{$key}->{daily_close};
        if ( defined $close and $close =~ /(\d+)h((\d+)m)?/) {
            my $hour = $1;
            my $min  = $3;
            if ($exchange_symbol eq 'ISE') {
                $hour += 6;
                $exchange_data->{market_times}->{$key}->{daily_settlement} = $hour . 'h' . $min . 'm';
            } elsif (
                grep {
                    $exchange_symbol eq $_
                } qw(TRSE NYSE NYSE_SPC NASDAQ NASDAQ_INDEX)
                )
            {
                $hour += 2;
                $exchange_data->{market_times}->{$key}->{daily_settlement} = $hour . 'h' .'59m' . '59s';
            }else {
                $hour += 3;
                if (defined $min and $min > 0){
                $exchange_data->{market_times}->{$key}->{daily_settlement} = $hour . 'h' . $min . 'm';
                }else {
                $exchange_data->{market_times}->{$key}->{daily_settlement} = $hour . 'h';
               }
            }
        }
        my $new_exch = BOM::MarketData::ExchangeConfig->new(
            %{$exchange_data},
            recorded_date => Date::Utility->new,
            symbol        => $exchange_symbol
        );
        $new_exch->save;
    }
}

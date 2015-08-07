package BOM::WebSocketAPI::Symbols;

use strict;
use warnings;

use BOM::Market::UnderlyingConfig;
use BOM::Market::Underlying;
use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);
use BOM::WebSocketAPI::Symbols;

# these package-level structures let us 'memo-ize' the symbol pools for purposes
# of full-list results and for hashed lookups by-displayname and by-symbol-code.

my ($_by_display_name, $_by_symbol, $_by_exchange) = ({}, {}, {});
for (BOM::Market::UnderlyingConfig->symbols) {
    my $sp = BOM::Market::UnderlyingConfig->get_parameters_for($_) || next;
    my $ul = BOM::Market::Underlying->new($_);
    $_by_display_name->{$ul->display_name} = $sp;
    # If this display-name has slashes, also generate a 'safe' version that can sit in REST expressions
    if ((my $safe_name = $ul->display_name) =~ s(/)(-)g) {
        $_by_display_name->{$safe_name} = $sp;
    }
    $_by_symbol->{$_} = $sp;
    push @{$_by_exchange->{$ul->exchange_name}}, $ul->display_name;
}

sub symbol_search {
    my $s = shift;
    return $_by_symbol->{$s} || $_by_display_name->{$s}    # or undef if not found.
}

sub _ticks {
    my (%args) = @_;
    my $ul    = $args{ul} || die 'no underlying';
    my $start = $args{start};
    my $end   = $args{end};
    my $count = $args{count};

    # we must not return to the client any ticks after this epoch
    my $licensed_epoch = $ul->last_licensed_display_epoch;
    my $when = DateTime->from_epoch(epoch => $licensed_epoch);

    unless ($start
        and $start =~ /^[0-9]+$/
        and $start > time - 365 * 86400
        and $start < $licensed_epoch)
    {
        $start = $licensed_epoch - 86400;
    }
    unless ($end
        and $end =~ /^[0-9]+$/
        and $end > $start
        and $end <= $licensed_epoch)
    {
        $end = $licensed_epoch;
    }
    unless ($count
        and $count =~ /^[0-9]+$/
        and $count > 0
        and $count < 5000)
    {
        $count = 500;
    }
    my $ticks = $ul->feed_api->ticks_start_end_with_limit_for_charting({
        start_time => $start,
        end_time   => $end,
        limit      => $count,
    });

    return [map { {time => $_->epoch, price => $_->quote} } reverse @$ticks];
}

1;

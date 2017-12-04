package BOM::Product::Contract::Finder::Japan;

use strict;
use warnings;

use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Quant::Framework;
use BOM::Platform::Chronicle;
use Exporter qw( import );
our @EXPORT_OK = qw(available_contracts_for_symbol);

use BOM::Product::Contract::PredefinedParameters qw(get_predefined_offerings);

=head1 available_contracts_for_symbol

Returns a set of available contracts for a particular contract which included predefined trading period and 20 predefined barriers associated with the trading period

=cut

sub available_contracts_for_symbol {
    my $args            = shift;
    my $symbol          = $args->{symbol} || die 'no symbol';
    my $underlying      = create_underlying($symbol, $args->{date});
    my $exchange        = $underlying->exchange;
    my $now             = $args->{date} || Date::Utility->new;
    my $landing_company = $args->{landing_company};
    my $country_code    = $args->{country_code} // '';

    my $calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
    my ($open, $close, $offerings);
    if ($calendar->trades_on($exchange, $now)) {
        $open = $calendar->opening_on($exchange, $now)->epoch;
        $close = $calendar->closing_on($exchange, $now)->epoch;
        $offerings = get_predefined_offerings({
            symbol          => $underlying->symbol,
            date            => $underlying->for_date,
            landing_company => $landing_company,
            country_code    => $country_code,
        });
    } else {
        $offerings = [];
    }

    return {
        available    => $offerings,
        hit_count    => scalar(@$offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

1;

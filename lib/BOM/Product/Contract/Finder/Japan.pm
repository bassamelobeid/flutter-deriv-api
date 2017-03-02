package BOM::Product::Contract::Finder::Japan;

use strict;
use warnings;

use Date::Utility;
use LandingCompany::Offerings qw(get_offerings_flyby);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
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
    my $now             = $args->{date} || Date::Utility->new;
    my $landing_company = $args->{landing_company};

    my $calendar = $underlying->calendar;
    my ($open, $close, $offerings);
    if ($calendar->trades_on($now)) {
        $open      = $calendar->opening_on($now)->epoch;
        $close     = $calendar->closing_on($now)->epoch;
        $offerings = get_predefined_offerings({
            symbol          => $underlying->symbol,
            date            => $underlying->for_date,
            landing_company => $landing_company,
        });
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

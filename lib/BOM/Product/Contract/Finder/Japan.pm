package BOM::Product::Contract::Finder::Japan;

use strict;
use warnings;

use Date::Utility;
use LandingCompany::Offerings qw(get_offerings_flyby);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::System::Chronicle;
use Exporter qw( import );
our @EXPORT_OK = qw(available_contracts_for_symbol);

use BOM::Product::Contract::PredefinedParameters qw(get_predefined_offerings);

=head1 available_contracts_for_symbol

Returns a set of available contracts for a particular contract which included predefined trading period and 20 predefined barriers associated with the trading period

=cut

sub available_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = create_underlying($symbol);
    my $now          = $args->{date} || Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $calendar = $underlying->calendar;
    my ($open, $close, @offerings);
    if ($calendar->trades_on($now)) {
        $open      = $calendar->opening_on($now)->epoch;
        $close     = $calendar->closing_on($now)->epoch;
        @offerings = get_predefined_offerings($underlying);
        foreach my $offering (@offerings) {
            my @expired_barriers = ();
            if ($offering->{barrier_category} eq 'american') {
                my ($high, $low);
                if ($underlying->for_date) {
                    # for historical access, we fetch ohlc directly from the database
                    ($high, $low) = @{
                        $underlying->get_high_low_for_period({
                                start => $date_start,
                                end   => $for_date
                            })}{'high', 'low'};
                } else {
                    my $highlow_key = join '_', ('highlow', $underlying->symbol, $date_start, $date_expiry);
                    my $cache = BOM::System::Chronicle::get_chronicle_reader->get($cache_namespace, $highlow_key);
                    if ($cache) {
                        ($high, $low) = ($cache->[0], $cache->[1]);
                    }
                }

                foreach my $barrier (@{$offering->{available_barriers}}) {
                    # for double barrier contracts, $barrier is [high, low]
                    if (ref $barrier eq 'ARRAY' and ($high > $barrier->[0] or $low < $barrier->[1])) {
                        push @expired_barriers, $barrier;
                    } elsif ($high > $barrier or $low < $barrier) {
                        push @expired_barriers, $barrier;
                    }
                }
            }
            $offering->{expired_barriers} = \@expired_barriers;
        }
    }

    return {
        available    => \@offerings,
        hit_count    => scalar(@offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

1;

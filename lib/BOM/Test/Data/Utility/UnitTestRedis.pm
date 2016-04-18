package BOM::Test::Data::Utility::UnitTestRedis;

use strict;
use warnings;

use File::Spec;
use Cwd qw/abs_path/;

use BOM::Market::Underlying;
use BOM::Market::AggTicks;

use base qw( Exporter );
our @EXPORT_OK = qw(initialize_realtime_ticks_db update_combined_realtime);

sub initialize_realtime_ticks_db {
    my %ticks = %{get_test_realtime_ticks()};
    for my $symbol (keys %ticks) {
        my $ul = BOM::Market::Underlying->new($symbol);
        $ticks{$symbol}->{epoch} = time + 600;
        $ul->set_combined_realtime($ticks{$symbol});
    }

    return;
}

sub get_test_realtime_ticks {
    my (undef, $file_path, undef) = File::Spec->splitpath(__FILE__);
    my $test_data_dir = abs_path("$file_path../../../../../data");

    return YAML::XS::LoadFile($test_data_dir . '/test_realtime_ticks.yml');
}

##################################################################################################
# update_combined_realtime(
#   datetime => $bom_date,            # tick time
#   underlying => $model_underlying,  # underlying
#   tick => {                         # tick data
#       open  => $open,
#       quote => $last_price,         # latest price
#       ticks => $numticks,           # number of ticks
#   },
#)
##################################################################################################
sub update_combined_realtime {
    my %args = @_;
    $args{underlying} = BOM::Market::Underlying->new($args{underlying_symbol});
    my $underlying_symbol = $args{underlying}->symbol;
    my $unixtime          = $args{datetime}->epoch;
    my $marketitem        = $args{underlying}->market->name;
    my $tick              = $args{tick};

    $tick->{epoch} = $unixtime;
    my $res = $args{underlying}->set_combined_realtime($tick);

    if (scalar grep { $args{underlying}->symbol eq $_ } (BOM::Market::UnderlyingDB->instance->symbols_for_intraday_fx)) {
        BOM::Market::AggTicks->new->add({
            symbol => $args{underlying}->symbol,
            epoch  => $tick->{epoch},
            quote  => $tick->{quote},
        });
    }
    return 1;
}

1;

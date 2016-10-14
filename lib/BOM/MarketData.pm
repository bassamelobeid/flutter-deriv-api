package BOM::MarketData;

use 5.010;
use strict;
use warnings;

use BOM::System::Chronicle;
use BOM::Platform::Runtime;
use BOM::Platform::Offerings qw(get_offerings_flyby);

use Quant::Framework::Underlying;
use Quant::Framework::UnderlyingDB;

use base qw( Exporter );
our @EXPORT_OK = qw( create_underlying create_underlying_db );

sub create_underlying {
    my $args     = shift;
    my $for_date = shift;

    if (not ref($args)) {
        my $symbol = $args;
        $args = {};
        $args->{symbol} = $symbol;
    }

    $for_date = $args->{for_date} if (exists $args->{for_date}) and not $for_date;

    $args->{chronicle_reader} = BOM::System::Chronicle::get_chronicle_reader($for_date);
    $args->{chronicle_writer} = BOM::System::Chronicle::get_chronicle_writer();

    my $result = Quant::Framework::Underlying->new($args, $for_date);

    return $result;
}

sub create_underlying_db {
    my $quant_config = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
    my $result       = Quant::Framework::UnderlyingDB->instance;

    $result->chronicle_reader(BOM::System::Chronicle::get_chronicle_reader);
    $result->chronicle_writer(BOM::System::Chronicle::get_chronicle_writer);
    $result->quant_config($quant_config);
    $result->offerings_flyby(get_offerings_flyby());

    return $result;

}

1;

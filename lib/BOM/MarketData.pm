package BOM::MarketData;

use 5.010;
use strict;
use warnings;

use BOM::System::Chronicle;
use BOM::Platform::Runtime;

use Quant::Framework::Underlying;
use Quant::Framework::UnderlyingDB;

use base qw( Exporter );
our @EXPORT_OK = qw( create_underlying create_underlying_db );

sub create_underlying {
    my $args = shift;
    my $for_date = shift;

    if ( not ref($args) ) {
        my $symbol = $args;
        $args = {};
        $args->{symbol} = $symbol;
    }

    $args->{chronicle_reader} = BOM::System::Chronicle::get_chronicle_reader($for_date);
    $args->{chronicle_writer} = BOM::System::Chronicle::get_chronicle_writer();

    return Quant::Framework::Underlying->new($args, $for_date);
}

sub create_underlying_db {
    my $quant_config = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
    my $result = Quant::Framework::UnderlyingDB->instance;

    $result->chronicle_reader(BOM::System::Chronicle::get_chronicle_reader);
    $result->chronicle_writer(BOM::System::Chronicle::get_chronicle_writer);
    $result->quant_config($quant_config);

    return $result;

}

1;

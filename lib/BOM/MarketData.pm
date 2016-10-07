package BOM::MarketData;

use 5.010;
use strict;
use warnings;

use BOM::System::Chronicle;
use Quant::Framework::Underlying;

use base qw( Exporter );
our @EXPORT_OK = qw( create_underlying create_underlying_db );

sub create_underlying {
    die "Underlying cannot have more than two inputs" if scalar @_ > 2;

    my $symbol;
    my $for_date;

    #input can be two scalar for symbol name and for_date
    if ( scalar @_ == 2 ) {
        $symbol = shift;
        $for_date = shift;
    } else {
        my $input = shift;


        #Input can be a scalar representing symbol name,
        if ( not ref($input) ) {
            $symbol = shift;
        } else {
            #input can be a hash-ref containing symbol and for_date
            my $hash_ref = shift;
            $symbol = $hash_ref->{symbol};
            $for_date = $hash_ref->{for_date} if exists $hash_ref->{for_date};
        }
    }

    return Quant::Framework::Underlying->new({
            symbol => $symbol,
            for_date => $for_date,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($for_date),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer()
        });
}

sub create_underlying_db {
    my $quant_config = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
    my $result = Quant::Framework::UnderlyingDB->instance;

    $result->chronicle_reader(BOM::System::Chronicle::get_chronicle_reader);
    $result->chronicle_writer(BOM::System::Chronicle::get_chronicle_writer);
    $result->quant_config($quant_config);

    return $result;

}

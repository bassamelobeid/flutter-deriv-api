package BOM::MarketData;

use 5.010;
use strict;
use warnings;

use BOM::Config::Chronicle;
use BOM::Config::Runtime;
use LandingCompany::Registry;

use Quant::Framework::Underlying;
use LandingCompany::UnderlyingDB;

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

    $args->{chronicle_reader} = BOM::Config::Chronicle::get_chronicle_reader($for_date);

    my $result = Quant::Framework::Underlying->new($args, $for_date);

    return $result;
}

sub create_underlying_db {
    my $quant_config = BOM::Config::Runtime->instance->app_config->quants->underlyings;
    my $result       = LandingCompany::UnderlyingDB->instance;

    $result->chronicle_reader(BOM::Config::Chronicle::get_chronicle_reader);
    $result->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer);
    $result->quant_config($quant_config);
    $result->offerings_flyby(LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config));

    return $result;
}

1;

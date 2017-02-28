package BOM::Test::Data::Utility::UnitTestRedis;

use strict;
use warnings;

use Dir::Self;
use Cwd qw/abs_path/;

use base qw( Exporter );
use Quant::Framework::Underlying;
use BOM::Test;

our @EXPORT_OK = qw(initialize_realtime_ticks_db);

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub initialize_realtime_ticks_db {
    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../../../../data");

    my %ticks = %{YAML::XS::LoadFile($test_data_dir . '/test_realtime_ticks.yml')};

    for my $symbol (keys %ticks) {
        my $args = {};
        $args->{symbol}           = $symbol;
        $args->{chronicle_reader} = BOM::Platform::Chronicle::get_chronicle_reader();
        $args->{chronicle_writer} = BOM::Platform::Chronicle::get_chronicle_writer();

        my $ul = Quant::Framework::Underlying->new($args);

        $ticks{$symbol}->{epoch} = time + 600;
        $ul->set_combined_realtime($ticks{$symbol});
    }

    return;
}

1;

use strict;
use warnings;

use Test::Most 0.22 (tests => 7);
use Test::MockTime qw(set_relative_time);
use Test::NoWarnings;
use YAML::XS qw(DumpFile LoadFile);

use BOM::Market::UnderlyingDB;

my $udb;
lives_ok {
    $udb = BOM::Market::UnderlyingDB->instance();
}
'Initialized';

isa_ok $udb, 'BOM::Market::UnderlyingDB', "Got instance";

is scalar($udb->symbols), 363, "DB initialized, all symbols loaded";
eq_or_diff [sort grep /^N/, $udb->symbols], [qw(N100 N150 N225 NAASML NAHEIA NAINGA NARDSA NAUNA NDX NIFTY NODNB NOSDRL NOSTL NOTEL NOYAR NZ50)],
    "/^N/ symbols are correct";

my @keys = $udb->symbols;
my @mismatch = grep { $_ ne $udb->get_parameters_for($_)->{symbol} } (@keys);
is(scalar @mismatch, 0, 'No symbols differ from underlyings.yml keys.');
foreach my $key (@mismatch) {
    diag 'Mismatched key [' . $key . '] and symbol [' . $udb->get_parameters_for($key)->{symbol} . ']';
}

my $sample_underlying = $udb->get_parameters_for('FCHI');
my $sample_expected   = {
    'contracts'         => 'limited_equities',
    'commission_level'  => 1,
    'display_name'      => 'French Index',
    'esig_symbol'       => '$PX1-EEB',
    'exchange_name'     => 'EURONEXT',
    'market'            => 'indices',
    'market_convention' => {
        delta_premium_adjusted => 0,
        delta_style            => 'spot_delta'
    },
    'pip_size'        => '0.01',
    'submarket'       => 'europe_africa',
    'asset'           => 'FCHI',
    'symbol'          => 'FCHI',
    'instrument_type' => 'stockindex',
    'feed_license'    => 'realtime',
    'quoted_currency' => 'EUR',
    'sd_symbol'       => 'CAC',
};
eq_or_diff $sample_underlying, $sample_expected, "correct data for sample underlying";

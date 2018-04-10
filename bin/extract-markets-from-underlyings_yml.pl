#!/etc/rmg/bin/perl

# this is supposed to be used by SRP when the underlyings.yml has changed.
# 1. make sure the Finance::Underlying module is up-to-date
# 2. call
#      bin/extract-markets-from-underlyings_yml.pl @psql-connection-params

use strict;
use warnings;
use YAML qw/LoadFile/;
use File::ShareDir ();

my $l=LoadFile(File::ShareDir::dist_file('Finance-Underlying', 'underlyings.yml'));

open my $psql, '|-', 'psql', '-X1', '-v', 'ON_ERROR_STOP=on', @ARGV;

print $psql "CREATE TEMP TABLE tt(LIKE bet.market) ON COMMIT DROP;\n";
print $psql "COPY tt(symbol, market, submarket) FROM stdin;\n";
print $psql "$_\t$l->{$_}->{market}\t$l->{$_}->{submarket}\n"
    for (sort keys %$l);
print $psql "\\.\n";
print $psql "INSERT INTO bet.market(symbol, market, submarket)\n";
print $psql "SELECT symbol, market, submarket FROM tt\n";
print $psql "ON CONFLICT(symbol) DO UPDATE\n";
print $psql "SET market=EXCLUDED.market, submarket=EXCLUDED.submarket;\n";

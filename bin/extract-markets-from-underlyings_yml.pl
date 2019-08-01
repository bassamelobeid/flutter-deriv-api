#!/etc/rmg/bin/perl

# This is supposed to be used by SRP when underlyings.yml has changed.
#
# 1. make sure the Finance::Underlying (public CPAN repo) module is up-to-date
# 2. call
#      bin/extract-markets-from-underlyings_yml.pl @psql-connection-params
#
# The output is a table of symbols that have been changed (inserted or updated).
#
# NOTE: bet.open_contract_aggregates and bet.global_aggregates do not have to
#       be re-recreated because of changes on bet.limits_market_mapper.

# NOTE: we should NOT delete symbols unless we are absolutely sure there are
#       no open contracts using them.

use strict;
use warnings;
use YAML qw/LoadFile/;
use File::ShareDir ();

my $l=LoadFile(File::ShareDir::dist_file('Finance-Underlying', 'underlyings.yml'));
my ($connection_param, $tablename) = @ARGV;
open my $psql, '|-', 'psql', '-X1', '-v', 'ON_ERROR_STOP=on', $connection_param;

print $psql <<"EOF";
CREATE TEMP TABLE tt(LIKE $tablename) ON COMMIT DROP;
COPY tt(symbol, market, submarket, market_type) FROM stdin;
EOF

print $psql "$_\t$l->{$_}->{market}\t$l->{$_}->{submarket}\t".(defined $l->{$_}->{market_type} ? $l->{$_}->{market_type} : 'financial')."\n"
    for (sort keys %$l);
print $psql "\\.\n";


print $psql <<"EOF";
INSERT INTO $tablename AS m(symbol, market, submarket, market_type)
SELECT symbol, market, submarket, market_type FROM tt
    ON CONFLICT(symbol) DO UPDATE
   SET market=EXCLUDED.market, submarket=EXCLUDED.submarket, market_type=EXCLUDED.market_type
 WHERE m.market IS DISTINCT FROM EXCLUDED.market
    OR m.submarket IS DISTINCT FROM EXCLUDED.submarket
    OR m.market_type IS DISTINCT FROM EXCLUDED.market_type
RETURNING *;
EOF

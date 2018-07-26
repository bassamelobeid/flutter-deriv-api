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
#       be re-recreated because of changes on bet.market.

# NOTE: we should NOT delete symbols unless we are absolutely sure there are
#       no open contracts using them.

use strict;
use warnings;
use YAML qw/LoadFile/;
use File::ShareDir ();

my $l=LoadFile(File::ShareDir::dist_file('Finance-Underlying', 'underlyings.yml'));

open my $psql, '|-', 'psql', '-X1', '-v', 'ON_ERROR_STOP=on', @ARGV;

print $psql <<'EOF';
CREATE TEMP TABLE tt(LIKE bet.market) ON COMMIT DROP;
COPY tt(symbol, market, submarket) FROM stdin;
EOF

print $psql "$_\t$l->{$_}->{market}\t$l->{$_}->{submarket}\n"
    for (sort keys %$l);
print $psql "\\.\n";


print $psql <<'EOF';
INSERT INTO bet.market AS m(symbol, market, submarket)
SELECT symbol, market, submarket FROM tt
    ON CONFLICT(symbol) DO UPDATE
   SET market=EXCLUDED.market, submarket=EXCLUDED.submarket
 WHERE m.market IS DISTINCT FROM EXCLUDED.market
    OR m.submarket IS DISTINCT FROM EXCLUDED.submarket
RETURNING *;
EOF

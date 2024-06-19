#!/etc/rmg/bin/perl

use strict;
use warnings;

use Text::CSV::Slurp;

my $csv = Text::CSV::Slurp->load(file => '/home/git/regentmarkets/bom-commission-management-service/config/ctrader_commission_rates.csv');
my ($connection_param, $tablename) = @ARGV;
open my $psql, '|-', 'psql', '-X1', '-v', 'ON_ERROR_STOP=on', $connection_param;

print $psql <<"EOF";
CREATE TEMP TABLE tt(LIKE $tablename) ON COMMIT DROP;
COPY tt(provider, account_type, type, mapped_symbol, commission_rate) FROM stdin;
EOF

foreach my $l (@$csv) {
    print $psql "$l->{provider}\t$l->{account_type}\t$l->{type}\t$l->{mapped_symbol}\t$l->{commission_rate}\n";
}

print $psql "\\.\n";

print $psql <<"EOF";
INSERT INTO $tablename AS m(provider, account_type, type, mapped_symbol, commission_rate)
SELECT provider, account_type, type, mapped_symbol, commission_rate FROM tt
    ON CONFLICT(provider, account_type, type, mapped_symbol) DO NOTHING
RETURNING *;
EOF

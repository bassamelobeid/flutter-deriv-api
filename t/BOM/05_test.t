use strict;
use warnings;
use Test::Most;
use BOM::Test;

my $environment = '';
my $expected_db_postfix;
if (open(my $fh, "</etc/rmg/environment")) {
    $environment = <$fh>;
    close($fh);
}

if ($environment =~ /^qa/) {
    $expected_db_postfix = '_test';
}

is($ENV{DB_POSTFIX}, $expected_db_postfix, 'the environment DB_POSTFIX should correct');

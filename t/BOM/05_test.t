use strict;
use warnings;
use Test::Most tests => 1;
use BOM::Test;

#I know this test is very bad.
#Who can tell me how to mock a file's content ?
#I don't want to change /etc/rmg/environment because this file is very important.
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

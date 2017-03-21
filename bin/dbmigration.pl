#!/etc/rmg/bin/perl -w
use strict;
use warnings;
use BOM::Database::Script::DBMigration;


exit BOM::Database::Script::DBMigration->new->run;

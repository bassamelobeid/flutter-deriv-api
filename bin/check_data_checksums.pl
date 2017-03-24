#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Script::CheckDataChecksums;

exit BOM::Database::Script::CheckDataChecksums::run();


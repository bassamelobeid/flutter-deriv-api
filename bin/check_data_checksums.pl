#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Database::Script::CheckDataChecksums;

local $| = 1;

exit BOM::Database::Script::CheckDataChecksums::run(@ARGV);


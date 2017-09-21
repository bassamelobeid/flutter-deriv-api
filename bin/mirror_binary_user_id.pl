#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::Script::MirrorBinaryUserId;

$BOM::Platform::Script::MirrorBinaryUserId::DEBUG = $ENV{DBG};
BOM::Platform::Script::MirrorBinaryUserId::run;

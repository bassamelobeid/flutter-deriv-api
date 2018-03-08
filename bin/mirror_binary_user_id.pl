#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::User::Script::MirrorBinaryUserId;

$BOM::User::Script::MirrorBinaryUserId::DEBUG = $ENV{DBG};
BOM::User::Script::MirrorBinaryUserId::run;

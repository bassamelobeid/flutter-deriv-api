#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::User::Script::MirrorBinaryUserId;

$BOM::User::Script::MirrorBinaryUserId::DEBUG = $ENV{DBG};
BOM::User::Script::MirrorBinaryUserId::run;

=head1 DESCIPTION

This script will copy user id from table user to binary_user_id in table client . So that we can get user directly by binary_user_id in table client.

=cut

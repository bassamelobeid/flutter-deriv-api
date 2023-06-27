#!/etc/rmg/bin/perl

use strict;
use warnings;

=head1 NAME
bom-feed-client.pl - Clients to feed
=head1 DESCRIPTION
Parent script for all the feed plugins
=cut

use BOM::FeedPlugin::Script::FeedClient;

exit BOM::FeedPlugin::Script::FeedClient::run();


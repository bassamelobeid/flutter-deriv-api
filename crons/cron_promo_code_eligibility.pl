#!/etc/rmg/bin/perl
use strict;
use warnings;

use BOM::Backoffice::Script::PromoCodeEligibility;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

=head2

Syncs promo codes with MyAffiliates and checks all clients for eligible promo codes.
Intended to be run a daily cron.

=cut

exit BOM::Backoffice::Script::PromoCodeEligibility::run();

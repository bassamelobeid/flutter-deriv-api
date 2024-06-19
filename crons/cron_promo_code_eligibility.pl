#!/etc/rmg/bin/perl
use strict;
use warnings;

use BOM::Backoffice::PromoCodeEligibility;

use Log::Any qw($log);
use Log::Any::Adapter qw(DERIV), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

=head2

Syncs promo codes with MyAffiliates and checks all clients for eligible promo codes.
Intended to be run a daily cron.

=cut

exit BOM::Backoffice::PromoCodeEligibility::approve_all();

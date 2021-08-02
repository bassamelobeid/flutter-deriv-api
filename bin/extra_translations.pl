#!/etc/rmg/bin/perl
use strict;
use warnings;
use Log::Any::Adapter 'DERIV';

use BOM::Backoffice::Script::ExtraTranslations;
exit BOM::Backoffice::Script::ExtraTranslations->new->run;

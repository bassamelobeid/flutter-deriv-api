#!/etc/rmg/bin/perl -w -I ./cgi -I ./cgi/oop
use strict;
use warnings;
use BOM::Backoffice::Script::ExtraTranslations;
exit BOM::Backoffice::Script::ExtraTranslations->new->run;

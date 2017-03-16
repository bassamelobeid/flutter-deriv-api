#!/etc/rmg/bin/perl -w -I ./cgi -I ./cgi/oop
use strict;
use warnings;
use BOM::Script::ExtraTranslations;
exit BOM::Script::ExtraTranslations->new->run;

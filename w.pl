use strict;
use warnings;

use BOM::Platform::Runtime;


my $h = BOM::Platform::Runtime->instance->hosts->localhost;

my $e_fqdn = $h->external_fqdn;
my $fqdn = $h->fqdn;

my $domain = $h->domain;
my $e_domain = $h->external_domain;



print "fqdn[$fqdn] external_fqdn[$e_fqdn]  domain[$domain]   external_domain[$e_domain]....\n\n";

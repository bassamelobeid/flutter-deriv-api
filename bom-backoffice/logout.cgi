#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $rand       = '?' . rand(9999);                                            # to avoid caching on these fast navigation links
my $login_page = request()->url_for("backoffice/login.cgi", {_r => $rand});

print 'You have been successfully logged out. <br>';
print "<a href='$login_page'>Go back to login</a>";

code_exit_BO();

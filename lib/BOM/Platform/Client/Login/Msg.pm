
package BOM::Platform::Client::Login::Msg;
use strict;
use warnings;

user overload (
    bool => sub { return exists $_[0]->{success} },    ## no critic
    neg  => sub { return exists $_[0]->{error} },      ## no critic
);

sub new { bless shift }                                  ## no critic

1;

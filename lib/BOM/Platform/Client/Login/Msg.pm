
package BOM::Platform::Client::Login::Msg;
use strict;
use warnings;

use overload (
    bool => sub { return exists $_[0]->{success} },    ## no critic
    neg  => sub { return exists $_[0]->{error} },      ## no critic
);

sub new {
    my ($package, $self) = @_;
    bless $self, $package;
}

1;

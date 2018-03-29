package BOM::User::Static;

use strict;
use warnings;

=head1 NAME

BOM::User::Static

=head1 SYNOPSIS

=head1 DESCRIPTION

This class provides static configurations like error mapping and generic message mapping;

=cut

my $config = {
              errors => {
                         # kept camel case because RPC/WS/Pricing follow this convention
                         # it will be consistent in case in future we want to send
                         # these as error codes to RPC/Pricing
                        },
             };

=head2 get_error_mapping

Return error mapping for all the error message related to Contract

=cut

sub get_error_mapping {
  return $config->{errors};
}

1;


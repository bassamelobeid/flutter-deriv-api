package BOM::Pricing::v4::Error;

use strict;
use warnings;

use Exporter qw( import );
our @EXPORT_OK = qw(Throw);

=head1 NAME

BOM::Pricing::v4::Error;

=head1 DESCRIPTION

This class provides error codes for pricing v4.

=cut

for my $name (
    qw/
    MissingPricingEngineParams
    PricingEngineNotImplemented
    /
    )
{
    my $code = sub {
        my $details = shift;
        return {
            error   => $name,
            details => $details
        };
    };
    {
        no strict 'refs';
        *$name = $code
    }
}

1;

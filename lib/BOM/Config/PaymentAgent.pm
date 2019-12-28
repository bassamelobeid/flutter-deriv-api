package BOM::Config::PaymentAgent;

use strict;
use warnings;
use BOM::Config;
use LandingCompany::Registry;
use Exporter;
our @EXPORT_OK = qw(get_transfer_min_max);

=head1 
 
This module is designed as a spot to centralise Configurations settings for payment
agents that require some logic over just reading the config yml file






=head2 get_transfer_min_max

Description: works out the maximum and minimum that the payment agent can transfer
Takes the following argument

=over 4

=item  currency :  A standard currency code  eg USD

=back

Returns a hashref with the minimum and maximum transfer amounts
    {
        minimum->$min_val, 
        maximum->$max_val
    }

=cut

sub get_transfer_min_max {
    my $currency = shift;
    die 'No currency is specified for PA limits' unless $currency;

    my $currency_type = LandingCompany::Registry::get_currency_type($currency);
    die "Invalid currency $currency for PA limits" unless $currency_type;

    my $min_max = BOM::Config::payment_agent()->{currency_specific_limits}->{$currency};
    # if no specific limit for currency drop back to defaults.
    $min_max = BOM::Config::payment_agent()->{payment_limits}->{$currency_type} if (!defined($min_max));
    return $min_max;
}

1;

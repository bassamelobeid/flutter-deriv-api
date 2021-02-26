package BOM::RPC::v3::PaymentMethods;

=head1 NAME

BOM::RPC::v3::PaymentMethods

=head1 DESCRIPTION

This is a package contains the handler sub for `payment_methods` rpc call.

=cut

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_inc);
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Config::Redis;

use BOM::Platform::Context qw(localize request);
use BOM::Platform::Doughflow qw(get_payment_methods);
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::User::Client;

=head2 payment_methods

Handle the C<payment_methods> API call.

As parameter receives a hashref with at least the following properties

=over 4

=item * C<args> - A hashref with the arguments received from the client.

=item * C<token_details> - A hashref with at least the attribute C<loginid>.

=back

The C<args> hashref should have the following atttributes :

=over 4

=item * C<payment_methods> - A number, always 1.

=item * C<country> - A string with the country as two letter code (ISO 3166-Alpha 2). Case insensitive.

=back

Will return a hashref with the payment_methods for this country brand/country code.

Further details about the structure can be found in L<BOM::Platform::Doughflow::get_payment_methods>.

=cut

rpc "payment_methods", sub {
    my $params        = shift;
    my $country       = $params->{args}->{country};
    my $token_details = $params->{token_details};
    my $brand         = request()->brand->name;

    $country = BOM::User::Client->new({loginid => $token_details->{loginid}})->residence
        if $token_details;
    try {
        my $ret = get_payment_methods($country, $brand);

        stats_inc('bom_rpc.v_3.no_payment_methods_found.count') unless scalar @$ret;

        return $ret;
    } catch ($error) {        
        if ($error =~ m/Unknown country code/) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UnknownCountryCode',
                    message_to_client => localize('Unknown country code.')});
        }
        
        die $error;
    }
};

1;

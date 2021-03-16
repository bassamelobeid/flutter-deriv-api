package BOM::Pricing::v3::PricingEndpoint;

use Moose;
use Syntax::Keyword::Try;
no indirect;

=head1 NAME

BOM::Pricing::v3::PricingEndpoint - A module that computes ask and bid price.

=head1 USAGE

    use BOM::Pricing::v3::PricingEndpoint;

    my $response = BOM::Pricing::v3::PricingEndpoint->new(params => {
       shortcode => 'DIGITMATCH_R_10_18.18_1517876791_5T_7_0',
       curency => 'USD'
    })->get();

=cut

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use List::Util qw(any);

=head2 params

Parameters from the request

=cut

has params => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

=head2 get

    my $response = $obj->get();

Return pricing response

=cut

sub get {
    my ($self) = @_;

    my $response;

    my $params = $self->params;

    my $contract            = produce_contract($params->{shortcode}, $params->{currency});
    my $contract_parameters = $contract->build_parameters;

    delete $contract_parameters->{date_start};

    $contract_parameters->{skip_contract_input_validation} = 1;
    $contract = produce_contract($contract_parameters);

    $response->{bid_price} = $contract->bid_price;
    $response->{ask_price} = $contract->ask_price;

    $response->{pricing_parameters}->{spot_time} = $contract->current_tick->epoch;

    if ($contract->underlying->feed_license eq 'realtime') {
        $response->{pricing_parameters}->{spot} = $contract->current_spot;
    }

    return $response;

}

no Moose;
__PACKAGE__->meta->make_immutable;

package BOM::Pricing::v4::PricingEndpoint;

use Moose;
use Syntax::Keyword::Try;
no indirect;

=head1 NAME

BOM::Pricing::v4::PricingEndpoint - A module that computes theo probably.

=head1 USAGE

    use BOM::Pricing::v4::PricingEndpoint;

    my $response = BOM::Pricing::v4::PricingEndpoint->new({
       shortcode => 'DIGITMATCH_R_10_18.18_1517876791_5T_7_0',
       currency => 'USD'
    })->get();

=cut

use BOM::Pricing::v4::Error;
use Finance::Underlying;
use Finance::Contract::Longcode qw(shortcode_to_longcode shortcode_to_parameters);
use Date::Utility;
use List::Util qw(any);
use Pricing::Engine::Digits;
use Pricing::Engine::HighLow::Ticks;
use Pricing::Engine::HighLow::Runs;

=head2 BUILD

Convert the given shortcode to contract parameters.

=cut

sub BUILD {
    my ($self, $args) = @_;
    my $parameters = shortcode_to_parameters($args->{shortcode}, $args->{currency});

    $self->parameters($parameters);
    $self->shortcode($args->{shortcode});
    $self->currency($args->{currency});
}

has [qw(parameters shortcode currency)] => (
    is => 'rw',
);

has [qw(
        pricing_engine_name
        pricing_engine
        )
] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 get

Get the theo probability from the pricing engine

=cut

sub get {
    my ($self) = @_;

    my $pricing_engine = $self->pricing_engine;

    return {theo_probability => $pricing_engine->theo_probability};
}

=head2 _build_pricing_engine

Creates the pricing engine instance

=cut

sub _build_pricing_engine {
    my $self = shift;
    my %pricing_parameters;

    if ($self->pricing_engine_name eq 'Pricing::Engine::Digits') {
        %pricing_parameters = (
            strike        => $self->parameters->{barrier},
            contract_type => $self->parameters->{bet_type},
        );
    }
    if ($self->pricing_engine_name eq 'Pricing::Engine::HighLow::Ticks') {
        %pricing_parameters = (
            contract_type => $self->parameters->{bet_type},
            selected_tick => $self->parameters->{selected_tick},
        );
    }
    if ($self->pricing_engine_name eq 'Pricing::Engine::HighLow::Runs') {
        my ($tick_count) = $self->parameters->{duration} =~ /^([0-9]+)t$/;
        %pricing_parameters = (
            contract_type => $self->parameters->{bet_type},
            selected_tick => $tick_count,
        );
    }

    # TODO: implement BS
    # elsif ($self->pricing_engine_name eq 'Pricing::Engine::BlackScholes') {
    #     %pricing_parameters = (
    #         %contract_config,
    #         t             => $self->timeinyears->amount,
    #         discount_rate => $self->discount_rate,
    #         mu            => $self->mu,
    #         vol           => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
    #     );
    # }

    my $required_args = $self->pricing_engine_name->required_args;
    if (my @missing_parameters = grep { !defined $pricing_parameters{$_} } @$required_args) {
        die BOM::Pricing::v4::Error::MissingPricingEngineParams({
            engine             => $self->pricing_engine_name,
            missing_parameters => \@missing_parameters
        });
    }
    return $self->pricing_engine_name->new(%pricing_parameters);
}

=head2 _build_pricing_engine_name

Select the approprate pricing engine based on the contract parameters

=cut

sub _build_pricing_engine_name {
    my $self = shift;

    my %engines = (
        DIGITMATCH => 'Pricing::Engine::Digits',
        DIGITDIFF  => 'Pricing::Engine::Digits',
        DIGITODD   => 'Pricing::Engine::Digits',
        DIGITEVEN  => 'Pricing::Engine::Digits',
        DIGITOVER  => 'Pricing::Engine::Digits',
        DIGITUNDER => 'Pricing::Engine::Digits',
        TICKLOW    => 'Pricing::Engine::HighLow::Ticks',
        TICKHIGH   => 'Pricing::Engine::HighLow::Ticks',
        RUNHIGH    => 'Pricing::Engine::HighLow::Runs',
        RUNLOW     => 'Pricing::Engine::HighLow::Runs',
    );

    if (defined $engines{$self->parameters->{bet_type}}) {
        return $engines{$self->parameters->{bet_type}};
    }

    my $underlying = Finance::Underlying->by_symbol($self->parameters->{underlying});
    # TODO support black scholse
    # if ($underlying->market eq 'synthetic_index') {
    #     return 'Pricing::Engine::BlackScholes';
    # }

    # TODO: support forex

    die BOM::Pricing::v4::Error::PricingEngineNotImplemented({
        bet_type => $self->parameters->{bet_type},
        market   => $underlying->market,
    });
}

no Moose;
__PACKAGE__->meta->make_immutable;

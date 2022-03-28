package BOM::Config::Payments::PaymentMethods;

use strict;
use warnings;

use BOM::Config::Runtime;
use JSON::MaybeUTF8;
use Moose;

=head2 new

Construct method. Make sure the app config is updated.

=cut

sub new {
    my ($class, %args) = @_;

    BOM::Config::Runtime->instance->app_config->check_for_update();

    return bless \%args, $class;
}

=head2 high_risk

Returns the high risk settings for the given payment method or C<undef> if 
the payment method is not high risk.

=cut

sub high_risk {
    my ($self, $pm) = @_;

    return $self->high_risk_settings()->{$pm};
}

=head2 high_risk_group

Returns the high risk group for the given payment method or C<undef> if 
the payment method is not high risk.

=cut

sub high_risk_group {
    my ($self, $pm) = @_;

    my $settings = $self->high_risk($pm);

    return undef unless $settings;

    return $settings->{group} // $pm;
}

=head2 high_risk_settings

The high risk settings from dynamic settings.

=cut

has 'high_risk_settings' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_high_risk_settings

Builds the hashref used for high risk.

Takes care of siblings so they match the big brother settings.

=cut

sub _build_high_risk_settings {
    my ($self) = @_;
    my $settings = JSON::MaybeUTF8::decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->payment_methods->high_risk);

    # make the siblings point to the big brother
    my $siblings = +{};
    for my $pm (keys $settings->%*) {
        $siblings = +{$siblings->%*, map { ($_ => +{group => $pm, $settings->{$pm}->%*}) } $settings->{$pm}->{siblings}->@*};
    }

    return +{$settings->%*, $siblings->%*,};
}

1

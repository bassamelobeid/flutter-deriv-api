package BOM::DisplayGreeks;

=head1 NAME

BOM::DisplayGreeks

=cut

=head1 DESCRIPTION

Return the display greeks in base and numeraire currency.
Currently, this package does not handle quanto

=cut

use Moose;
use Data::Dumper;

=head2 bet

The bet object

=cut

has [qw(payout priced_with pricing_greeks current_spot underlying)] => (
    is => 'ro',
);

=head2 get_display_greeks

Greeks in proper unit and these value is multiplied by the payout amount of the bet

=cut

has 'get_display_greeks' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_get_display_greeks {
    my $self       = shift;
    my $underlying = $self->bet->underlying;
    my $display_greeks;

    foreach my $greek (keys %{$self->pricing_greeks}) {
        $display_greeks->{$greek} = $self->$greek();
    }
    return $self->_get_base_num_values($display_greeks);
}

sub _get_base_num_values {
    my ($self, $display_greeks) = @_;
    my $payout = $self->payout;
    my $S      = $self->bet->current_spot;
    my $pw     = $self->priced_with;

    my $base_num;
    foreach my $greek (keys %$display_greeks) {
        if (grep { $greek eq $_ } qw(delta vanna gamma)) {
            $base_num->{$greek}->{base}   = $display_greeks->{$greek} * $payout;
            $base_num->{$greek}->{num}    = $display_greeks->{$greek} * $S * $payout;    # delta, gamma, vanna are always in foreign unit
            $base_num->{$greek}->{quanto} = $display_greeks->{$greek} * $S * $payout;    # this is wrong but we don't want to deal with it for now
        } elsif (
            grep {
                $greek eq $_
            } qw(theta volga vega)
            )
        {
            $base_num->{$greek}->{base} =
                  ($pw eq 'base') ? $display_greeks->{$greek} * $payout
                : (grep { $pw eq $_ } qw(numeraire quanto)) ? $display_greeks->{$greek} / $S * $payout
                :                                             undef;
            $base_num->{$greek}->{num} =
                  ($pw eq 'base') ? $display_greeks->{$greek} * $S * $payout
                : (grep { $pw eq $_ } qw(numeraire quanto)) ? $display_greeks->{$greek} * $payout
                :                                             undef;
        }
    }
    return $base_num;
}

has 'delta' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_delta {
    my $self          = shift;
    my $pw            = $self->priced_with;
    my $S             = $self->bet->current_spot;
    my $pricing_delta = $self->pricing_greeks->{delta};

    return
          ($pw eq 'numeraire') ? $pricing_delta
        : ($pw eq 'base')      ? $pricing_delta * $S
        : ($pw eq 'quanto')    ? $pricing_delta * $S
        :                        undef;
}

has 'gamma' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_gamma {
    my $self          = shift;
    my $pw            = $self->priced_with;
    my $S             = $self->bet->current_spot;
    my $pricing_gamma = $self->pricing_greeks->{gamma};

    return
          ($pw eq 'numeraire') ? $pricing_gamma * $S
        : ($pw eq 'base')   ? $pricing_gamma * ($S**2)
        : ($pw eq 'quanto') ? $pricing_gamma * ($S**2)
        :                     undef;
}

has 'vega' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_vega {
    my $self         = shift;
    my $pw           = $self->priced_with;
    my $pricing_vega = $self->pricing_greeks->{vega};

    return
          ($pw eq 'numeraire') ? $pricing_vega
        : ($pw eq 'base')      ? $pricing_vega
        : ($pw eq 'quanto')    ? $pricing_vega
        :                        undef;
}

has 'theta' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_theta {
    my $self          = shift;
    my $pw            = $self->priced_with;
    my $pricing_theta = $self->pricing_greeks->{theta};

    return
          ($pw eq 'numeraire') ? $pricing_theta
        : ($pw eq 'base')      ? $pricing_theta
        : ($pw eq 'quanto')    ? $pricing_theta
        :                        undef;
}

has 'vanna' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_vanna {
    my $self          = shift;
    my $pw            = $self->priced_with;
    my $S             = $self->bet->current_spot;
    my $pricing_vanna = $self->pricing_greeks->{vanna};

    return
          ($pw eq 'numeraire') ? $pricing_vanna
        : ($pw eq 'base')      ? $pricing_vanna * $S
        : ($pw eq 'quanto')    ? $pricing_vanna * $S
        :                        undef;
}

has 'volga' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_volga {
    my $self          = shift;
    my $pw            = $self->priced_with;
    my $pricing_volga = $self->pricing_greeks->{volga};

    return
          ($pw eq 'numeraire') ? $pricing_volga
        : ($pw eq 'base')      ? $pricing_volga
        : ($pw eq 'quanto')    ? $pricing_volga
        :                        undef;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

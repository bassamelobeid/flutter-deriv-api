package BOM::Product::Contract::Invalid;

use Moose;
extends 'BOM::Product::Contract';

use BOM::Platform::Context qw(localize);

sub value     { return 0 }
sub is_legacy { return 1 }

# it is just here to show which type is invalid
has bet_type => (
    is => 'ro',
);

has 'code' => (
    is      => 'ro',
    default => sub { shift->bet_type },
);

# Previously we were passing in a dummy expiry
# (1s after 1970-01-01). We override date_expiry
# to avoid that here: the actual value is just
# as invalid (expiry == start).
has 'date_expiry' => (
    is         => 'ro',
    isa        => 'date_object',
    lazy_build => 1,
);

sub _build_date_expiry {
    my ($self) = @_;
    return $self->date_start;
}

sub _build_longcode {
    return localize('Legacy contract. No further information is available.');
}

sub _price_from_prob        { die "Can not price legacy bet: " . shift->shortcode; }
sub _build_shortcode        { die "Invalid legacy bet type[" . shift->code . ']'; }
sub is_expired              { return 1; }
sub is_settleable           { return 1; }
sub _build_ask_probability  { return 1; }
sub _build_bid_probability  { return 1; }
sub _build_theo_probability { return 1; }
sub _build_bs_probability   { return 1; }
sub is_valid_to_buy         { return 0; }
sub is_valid_to_sell        { return 0 }

no Moose;
__PACKAGE__->meta->make_immutable;
1;

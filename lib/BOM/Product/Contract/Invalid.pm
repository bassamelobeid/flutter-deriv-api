package BOM::Product::Contract::Invalid;

use Moose;
extends 'BOM::Product::Contract';

use BOM::Product::Static qw/get_longcodes get_error_mapping/;

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

sub longcode {
    return [get_longcodes()->{legacy_contract}];
}

sub _price_from_prob        { die "Can not price legacy bet: " . shift->shortcode; }
sub shortcode               { die "Invalid legacy bet type[" . shift->code . ']'; }
sub is_expired              { return 1; }
sub is_settleable           { return 1; }
sub is_atm_bet              { return 1; }
sub _build_ask_probability  { return 1; }
sub _build_bid_probability  { return 1; }
sub _build_theo_probability { return 1; }
sub _build_bs_probability   { return 1; }

sub is_valid_to_buy {
    my $self = shift;
    $self->_add_error({
        message           => 'Invalid legacy contract',
        message_to_client => [get_error_mapping()->{CannotValidateContract}],
    });
    return 0;
}

sub is_valid_to_sell {
    my $self = shift;
    $self->_add_error({
        message           => 'Invalid legacy contract',
        message_to_client => [get_error_mapping()->{CannotValidateContract}],
    });
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

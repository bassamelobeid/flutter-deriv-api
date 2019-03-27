package BOM::Product::Contract::Invalid;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary';

use BOM::Product::Static qw/get_error_mapping/;
use Finance::Contract::Longcode qw(get_longcodes);

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

sub longcode {
    return [get_longcodes()->{legacy_contract}];
}

sub _price_from_prob {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidContractType',
        details    => {field => 'contract_type'},
    );
}

sub shortcode {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidContractType',
        details    => {field => 'contract_type'},
    );
}

sub is_expired              { return 1; }
sub is_settleable           { return 1; }
sub is_atm_bet              { return 1; }
sub _build_ask_probability  { return 1; }
sub _build_bid_probability  { return 1; }
sub _build_theo_probability { return 1; }
sub _build_bs_probability   { return 1; }
sub barrier_category        { return 1; }

sub is_valid_to_buy {
    my $self = shift;
    $self->_add_error({
        message           => 'Invalid legacy contract',
        message_to_client => [get_error_mapping()->{CannotValidateContract}],
        details           => {},
    });
    return 0;
}

sub is_valid_to_sell {
    my $self = shift;
    $self->_add_error({
        message           => 'Invalid legacy contract',
        message_to_client => [get_error_mapping()->{CannotValidateContract}],
        details           => {},
    });
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

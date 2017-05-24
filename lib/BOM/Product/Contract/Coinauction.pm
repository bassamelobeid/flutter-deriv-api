package BOM::Product::Contract::Coinauction;

use Moose;

with 'MooseX::Role::Validatable';
use Quant::Framework::Underlying;
use Finance::Contract;
use BOM::Platform::Context qw(localize);
has [qw(id display_name)] => (is => 'ro');

# Actual methods for introspection purposes.
sub is_coinauction      { return 1 }
sub is_legacy           { return 0 }
sub is_atm_bet          { return 0 }
sub is_intraday         { return 0 }
sub is_forward_starting { return 0 }

# This is to indicate whether this is a sale transaction.
has _for_sale => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);
has [qw(number_of_tokens token_type coin_address)] => (
    is => 'rw',
);

has underlying => (
    is       => 'ro',
    isa      => 'underlying_object',
    coerce   => 1,
    required => 1,
);

sub BUILD {
    my $self = shift;

    my $limits = {
        min => 1,
        max => 1000000,
    };

    $self->token_type($self->contract_type);
    $self->coin_address($self->underlying->symbol);

    if ($self->number_of_tokens < $limits{min} or $self->number_of_tokens > $limits->{max}) {

        $self->add_errors({
            message => 'number of tokens placed is not within limits '
                . "[given: "
                . $self->number_of_tokens . "] "
                . "[min: "
                . $limits->{min} . "] "
                . "[max: "
                . $limits->{max} . "]",
            severity => 99,
            message_to_client =>
                localize('Number of token placed must be between [_1] and [_2] [_3].', $limits->{min}, $limits->{max}, $self->currency),
            message_to_client_array => ['Amount Per Point must be between [_1] and [_2] [_3].', $limits->{min}, $limits->{max}, $self->currency],
        });
    }

    return;
}


has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has date_start => (
    is         => 'ro',
    isa        => 'date_object',
    coerce     => 1,
    lazy_build => 1,
);

# TODO: This should be a hardcoded auction period start
sub _build_date_start {
    my $self = shift;

    return $self->trading_period_start;

}

has date_pricing => (
    is      => 'ro',
    isa     => 'date_object',
    coerce  => 1,
    default => sub { Date::Utility->new },
);

has [qw(date_expiry date_settlement)] => (
    is         => 'ro',
    isa        => 'date_object',
    lazy_build => 1,
);

# TODO :We need to decide the duration of the auction
sub _build_date_expiry {
    my $self = shift;
    return $self->date_start->plus_time_interval('30d');
}

sub _build_date_settlement {
    return shift->date_expiry;
}

has [qw(is_valid_to_buy is_valid_to_sell)] => (
    is         => 'ro',
    lazy_build => 1,
);

has is_sold => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

sub _build_is_valid_to_buy {
    my $self = shift;

    return $self->confirm_validity;
}

sub _build_is_valid_to_sell {
    my $self = shift;

    if ($self->date_pricing->is_after($self->date_expiry)) {
        $self->add_errors({
            message           => 'Auction already sold',
            severity          => 99,
            message_to_client => localize("This auction has been closed."),
        });
        return 0;
    }

    return $self->confirm_validity;
}

has [qw(shortcode)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_shortcode {
    my $self = shift;

    my @element = map { uc $_ } ($self->token_type, $self->coin_addresss, $self->ask_price, $self->number_of_tokens);
    return join '_', @element;
}


sub longcode {
    my $self        = shift;
    my $description = $self->localizable_description->{'coinauction'};
    my $coin_naming = $self->token_type eq 'ERC20ICO'? 'ERC20 Ethereum token' : 'ICO coloured coin';

    return localize($description,($coin_naming, $self->coin_address);

}

sub is_expired {
    my $self = shift;

    return $self->date_pricing->is_after($self->date_expiry) ? 1 : 0;
}

sub is_settleable {
    my $self = shift;

    return $self->is_expired // 0;

}

# Validation
sub _validate_token_type {
    my $self = shift;

    my @err;
    my @supported_token = Finance::Contract::Category->new("coinauction")->{available_types};

    if (grep { $_ ne $self->token_type } @supported_token) {
        push @err,
            {
            message           => "Invalid token type. [symbol: " . $self->token_type . "]",
            severity          => 98,
            message_to_client => localize('We are not support auction with this token ' . $self->token_type),
            };
    }

    return @err;
}

sub _validate_price {
    my $self = shift;

    return 1 if $self->for_sale;

    my @err;
    if ($self->ask_price > 0) {
        push @err,
            {
            message           => 'The auction bid price can not be less than zero .' severity => 99,
            message_to_client => localize('The auction bid price can not be less than zero.'),
            };
    }

    return @err;
}

sub _validate_date_pricing {
    my $self = shift;

    return 1 if $self->for_sale;

    my @err;
    if ($self->date_pricing->is_after($self->date_expiry)) {
        push @err,
            {
            message           => 'The auction is already closed.' severity => 99,
            message_to_client => localize('The ICO auction is already closed.'),
            };
    }

    return @err;

}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
A

package BOM::Product::Contract::Coinauction;

use Moose;

with 'MooseX::Role::Validatable';
use Quant::Framework::Underlying;
use Finance::Contract;
use BOM::Product::Static qw/get_longcodes get_error_mapping/;
use List::Util qw(first);
# Actual methods for introspection purposes.
sub is_coinauction      { return 1 }
sub is_legacy           { return 0 }
sub is_atm_bet          { return 0 }
sub is_intraday         { return 0 }
sub is_forward_starting { return 0 }

use constant {    # added for Transaction
    expiry_daily        => 0,
    fixed_expiry        => 0,
    tick_expiry         => 0,
    pricing_engine_name => '',
};

# This is to indicate whether this is a sale transaction.

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has _for_sale => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);
has [qw(trading_period_start number_of_tokens token_type coin_address ask_price)] => (
    is => 'rw',
);

has app_markup_dollar_amount => (
    is      => 'ro',
    isa     => 'Num',
    default => 0,
);

has underlying => (
    is       => 'ro',
    isa      => 'underlying_object',
    coerce   => 1,
    required => 1,
);

has payout => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_payout {
    my $self = shift;
    return $self->ask_price;
}

has build_parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

sub BUILD {
    my $self   = shift;
    my $limits = {
        min => 1,
        max => 1000000,
    };
    $self->token_type($self->build_parameters->{bet_type});
    $self->coin_address($self->underlying->symbol);
    $self->trading_period_start(Date::Utility->new($self->build_parameters->{trading_period_start}));

    if ($self->number_of_tokens < $limits->{min} or $self->number_of_tokens > $limits->{max}) {

        $self->add_errors({
            message => 'number of tokens placed is not within limits '
                . "[given: "
                . $self->number_of_tokens . "] "
                . "[min: "
                . $limits->{min} . "] "
                . "[max: "
                . $limits->{max} . "]",
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{IcoTokenLimits}, $limits->{min}, $limits->{max}],
        });
    }

    return;
}

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has [qw(date_expiry date_settlement)] => (
    is         => 'ro',
    isa        => 'date_object',
    lazy_build => 1,
);

has date_start => (
    is         => 'rw',
    isa        => 'date_object',
    coerce     => 1,
    lazy_build => 1,
);


sub _build_date_start {
    return Date::Utility->new;

}

has date_pricing => (
    is      => 'rw',
    isa     => 'date_object',
    default => sub { Date::Utility->new },
);


# TODO :We need to decide the duration of the auction
sub _build_date_expiry {
    my $self = shift;
    return $self->trading_period_start->plus_time_interval('30d');
}

sub _build_date_settlement {
    return shift->date_expiry;
}

has [qw(is_valid_to_buy is_valid_to_sell)] => (
    is         => 'rw',
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

    $self->_for_sale(1);
    if ($self->date_pricing->is_after($self->date_expiry)) {
        $self->add_errors({
            message           => 'Auction already closed',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{IcoClosed}],
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
    my @element = map { uc $_ } ($self->token_type, $self->coin_address, $self->ask_price, $self->number_of_tokens);
    return join '_', @element;
}

sub longcode {
    my $self        = shift;
    my $description = get_longcodes()->{'coinauction'};
    my $coin_naming = $self->token_type eq 'ERC20ICO' ? 'ERC20 Ethereum token' : 'ICO coloured coin';
    return [$description, $coin_naming, $self->coin_address];

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
    my $supported_token = Finance::Contract::Category->new("coinauction")->{available_types};
    my $token_type      = uc($self->token_type);
    if (not grep { $_ eq $token_type } @$supported_token) {
        push @err,
            {
            message           => "Invalid token type. [symbol: " . $self->token_type . "]",
            severity          => 98,
            message_to_client => [$ERROR_MAPPING->{InvalidIcoToken}, $self->token_type],
            };
    }

    return @err;
}

sub _validate_price {
    my $self = shift;

    return if $self->_for_sale;

    my @err;
    if ($self->ask_price < 0) {
        push @err,
            {
            message           => 'The auction bid price can not be less than zero .',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{InvalidIcoBidPrice}],
            };
    }

    return @err;
}

sub _validate_date_pricing {
    my $self = shift;

    return if $self->_for_sale;

    my @err;
    if ($self->date_pricing->is_after($self->date_expiry)) {
        push @err,
            {
            message           => 'The auction is already closed.',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{IcoClosed}],
            };
    }

    return @err;

}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

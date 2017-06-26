package BOM::Product::Contract::Coinauction;

use Moose;

with 'MooseX::Role::Validatable';
use Quant::Framework::Underlying;
use Finance::Contract;
use BOM::Product::Static qw/get_longcodes get_error_mapping/;
use List::Util qw(first);
# Actual methods for introspection purposes.
sub is_binaryico      { return 1 }
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

my $ICO_config = {
    'BINARYICO' => {binaryico_auction_date_start => 1496275200}

};

has _for_sale => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);
has [qw(binaryico_number_of_tokens contract_type binaryico_per_token_bid_price)] => (
    is => 'rw',
);

has ask_price => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
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

sub _build_ask_price {
    my $self = shift;
    return $self->binaryico_number_of_tokens * $self->binaryico_per_token_bid_price;
}

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
    $self->contract_type($self->build_parameters->{bet_type});
    $self->binaryico_number_of_tokens($self->build_parameters->{binaryico_number_of_tokens});
    $self->binaryico_per_token_bid_price($self->build_parameters->{binaryico_per_token_bid_price});
    if ($self->binaryico_number_of_tokens < $limits->{min} or $self->binaryico_number_of_tokens > $limits->{max}) {

        $self->add_errors({
            message => 'number of tokens placed is not within limits '
                . "[given: "
                . $self->binaryico_number_of_tokens . "] "
                . "[min: "
                . $limits->{min} . "] "
                . "[max: "
                . $limits->{max} . "]",
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{BinaryicoTokenLimits}, $limits->{min}, $limits->{max}],
        });
    }

    return;
}

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has [qw(date_expiry date_settlement date_start binaryico_auction_date_start)] => (
    is         => 'rw',
    isa        => 'date_object',
    lazy_build => 1,
);

sub _build_date_start {
    my $self = shift;
    my $now  = Date::Utility->new;

    return $now->is_after($self->date_expiry) ? $self->date_expiry : $now;

}

sub _build_binaryico_auction_date_start {
    my $self = shift;

    if (not $ICO_config->{$self->contract_type}) {
        $self->add_errors({
            message => "Invalid contract type. [symbol: " . $self->contract_type . "]",
            ,
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{InvalidBinaryicoContract}, $self->contract_type],
        });
        return Date::Utility->new;

    }

    return Date::Utility->new($ICO_config->{$self->contract_type}->{binaryico_auction_date_start});

}

has date_pricing => (
    is      => 'rw',
    isa     => 'date_object',
    default => sub { Date::Utility->new },
);

sub _build_date_expiry {
    my $self = shift;

    return $self->binaryico_auction_date_start->plus_time_interval('30d');
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
    my $self          = shift;
    my $contract_type = uc($self->contract_type);
    my @element       = map { $_ } ($contract_type, $self->binaryico_per_token_bid_price, $self->binaryico_number_of_tokens);
    return join '_', @element;
}
sub longcode {
    my $self        = shift;
    my $description = get_longcodes()->{'binaryico'};
    return [$description];    

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
sub _validate_price {
    my $self = shift;

    return if $self->_for_sale;

    my @err;
    if (not $self->ask_price or $self->ask_price == 0) {
        push @err, {
            message           => 'The auction total bid price can not be less than zero .',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{InvalidBinaryicoBidPrice}],

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

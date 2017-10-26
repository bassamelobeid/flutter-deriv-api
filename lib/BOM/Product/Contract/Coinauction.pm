package BOM::Product::Contract::Coinauction;

use Moose;
use Date::Utility;
use Quant::Framework::Underlying;
use Format::Util::Numbers qw/financialrounding/;

use Postgres::FeedDB::CurrencyConverter qw (in_USD);

with 'MooseX::Role::Validatable';
extends 'Finance::Contract';
use BOM::MarketData::Types;
use BOM::Product::Static qw(get_error_mapping);
use BOM::Platform::Runtime;

# Actual methods for introspection purposes.
sub is_binaryico        { return 1 }
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

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has _for_sale => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has [qw(binaryico_number_of_tokens contract_type binaryico_per_token_bid_price binaryico_per_token_bid_price_USD binaryico_auction_status)] => (
    is => 'rw',
);

has ask_price => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

has binaryico_auction_status => (
    is         => 'rw',
    lazy_build => 1,
);

has bid_price => (
    is      => 'rw',
    isa     => 'Num',
    default => 0,
);

has underlying => (
    is       => 'ro',
    isa      => 'underlying_object',
    coerce   => 1,
    required => 1,
);

has app_markup_dollar_amount => (
    is      => 'ro',
    isa     => 'Num',
    default => 0,
);

has payout => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

has auction_ended => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
);

has auction_started => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
);

has auction_final_price => (
    is         => 'ro',
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

sub _build_auction_started {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->is_auction_started;
}

sub _build_auction_ended {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->is_auction_ended;
}

sub _build_auction_final_price {
    return BOM::Platform::Runtime->instance->app_config->system->suspend->ico_final_price;
}

sub _build_binaryico_auction_status {
    my $self = shift;

    if ($self->auction_ended) {
        if ($self->binaryico_per_token_bid_price_USD < $self->auction_final_price) {
            $self->bid_price($self->ask_price);
            return 'unsuccessful bid';
        } else {
            $self->bid_price(0);
            return 'successful bid';
        }
    } else {
        $self->bid_price($self->ask_price * 0.98);
        return 'bid';
    }

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
    $self->binaryico_per_token_bid_price_USD(
        financialrounding('price', $self->currency, in_USD($self->binaryico_per_token_bid_price, $self->currency)));
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
            message_to_client => [$ERROR_MAPPING->{BinaryIcoTokenLimits}, $limits->{min}, $limits->{max}],
        });
    }

    return;
}

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has [qw(date_expiry date_settlement date_start)] => (
    is         => 'rw',
    isa        => 'date_object',
    lazy_build => 1,
);

sub _build_date_start {
    my $self = shift;

    return Date::Utility->new;
}

has date_pricing => (
    is      => 'rw',
    isa     => 'date_object',
    default => sub { Date::Utility->new },
);

sub _build_date_expiry {
    my $self = shift;

    return Date::Utility->new->plus_time_interval('600d');
}

sub _build_date_settlement {
    return shift->date_expiry;
}

has is_sold => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

sub is_valid_to_buy {
    my $self = shift;

    return $self->confirm_validity;
}

sub _validate_auction_started {
    my $self = shift;

    unless ($self->auction_started) {
        return {
            message           => 'ICO has not yet started.',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{IcoNotStarted}],
        };
    }

    return;
}

sub is_valid_to_sell {
    my $self = shift;

    $self->_for_sale(1);

    return 1 if ($self->binaryico_auction_status eq 'unsuccessful bid' or $self->binaryico_auction_status eq 'bid');

    return 0;

}

has [qw(shortcode)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_shortcode {
    my $self = shift;
    return join '_', uc($self->contract_type), $self->binaryico_per_token_bid_price, $self->binaryico_number_of_tokens;
}

sub longcode {
    my $self = shift;
    return 'Binary ICO: ' . $self->binaryico_auction_status;
}

sub is_expired {
    my $self = shift;

    return ($self->auction_ended) ? 1 : 0;
}

sub is_settleable {
    my $self = shift;

    return $self->is_expired // 0;

}

# Validation

sub _validate_price {
    my $self = shift;

    return if $self->_for_sale;

    if ($self->binaryico_per_token_bid_price_USD < 1) {
        return {
            message           => 'The minimum bid is USD 1 or equivalent in other currency.',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{InvalidBinaryIcoBidPrice}],
        };

    }
    return;
}

sub _validate_date_pricing {
    my $self = shift;

    return if $self->_for_sale;

    if ($self->auction_ended) {
        return {
            message           => 'The auction is already closed.',
            severity          => 99,
            message_to_client => [$ERROR_MAPPING->{IcoClosed}],
        };
    }

    return;

}

sub pricing_details {
    my $self = shift;
    return [
        binaryico_number_of_tokens    => $self->binaryico_number_of_tokens,
        binaryico_per_token_bid_price => $self->binaryico_per_token_bid_price
    ];
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

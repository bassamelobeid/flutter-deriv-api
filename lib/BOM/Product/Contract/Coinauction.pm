package BOM::Product::Contract::Coinauction;

use Moose;

with 'MooseX::Role::Validatable';
use Quant::Framework::Underlying;
use Finance::Contract;
use BOM::Product::Static qw/get_longcodes get_error_mapping/;
use List::Util qw(first);
use Date::Utility;
use BOM::Platform::Runtime;
use Postgres::FeedDB::CurrencyConverter qw (in_USD);

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

my $app_config          = BOM::Platform::Runtime->instance->app_config;
my $is_auction_ended    = $app_config->system->auction_ended;
my $auction_final_price = 1.09;                                           # just for testing

has _for_sale => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has [qw(binaryico_number_of_tokens contract_type binaryico_per_token_bid_price binaryico_per_token_bid_price_USD)] => (
    is => 'rw',
);

has ask_price => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

has bid_price => (
    is  => 'rw',
    isa => 'Num',
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
    $self->binaryico_per_token_bid_price_USD(in_USD($self->binaryico_per_token_bid_price, $self->currency));
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

    return 0 if $is_auction_ended;
    return $self->confirm_validity;
}

sub _build_is_valid_to_sell {
    my $self = shift;

    $self->_for_sale(1);

    if ($is_auction_ended) {
        if ($self->binaryico_per_token_bid_price_USD < $auction_final_price) {
            $self->bid_price($self->ask_price);
            return 1;
        } else {
            $self->bid_price(0);
            return 0;
        }
    } else {
        $self->bid_price($self->ask_price * 0.98);
        return 1;
    }
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
    return [get_longcodes()->{'binaryico'}];
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
    if ($self->binaryico_per_token_bid_price_USD <= 1) {
        push @err, {
            message  => 'The minimum bid is USD 1 or equivalent in other currency.',
            severity => 99,
            message_to_client =>
                [$ERROR_MAPPING->{InvalidBinaryIcoBidPrice}, $self->currency, $self->binaryico_per_token_bid_price, $per_token_bid_price_in_usd],

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

sub pricing_details {
    my ($self, $action) = @_;

    return [
        binaryico_number_of_tokens    => $self->binaryico_number_of_tokens,
        binaryico_per_token_bid_price => $self->binaryico_per_token_bid_price
    ];
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

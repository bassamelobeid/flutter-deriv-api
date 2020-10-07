package BOM::Product::ContractFinder;

use Moose;
use Date::Utility;
use Quant::Framework;
use LandingCompany::Registry;

use BOM::Product::ContractFinder::Basic;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);

has for_date => (
    is      => 'ro',
    default => undef,
);

sub basic_contracts_for {
    my ($self, $args) = @_;

    $args->{product_type} = 'basic';
    return $self->_get_contracts($args);
}

## PRIVATE

sub _get_contracts {
    my ($self, $args) = @_;

    my $symbol                = $args->{symbol} // die 'symbol is require';
    my $landing_company_short = $args->{landing_company};
    my $country_code          = $args->{country_code} // '';                               # might not be defined
    my $product_type          = $args->{product_type} // die 'product_type is required';

    my $date       = $self->for_date // Date::Utility->new;
    my $underlying = create_underlying($args->{symbol}, $self->for_date);
    my $exchange   = $underlying->exchange;
    my $calendar   = $self->_trading_calendar;

    my ($offerings, $open, $close) = ([]);
    if ($calendar->trades_on($exchange, $date)) {
        $open  = $calendar->opening_on($exchange, $date)->epoch;
        $close = $calendar->closing_on($exchange, $date)->epoch;
    }

    my $deco_args = {
        underlying            => $underlying,
        calendar              => $calendar,
        date                  => $date,
        landing_company_short => $landing_company_short,
    };
    if ($product_type eq 'basic') {
        $deco_args->{offerings} = _get_basic_offerings($symbol, $landing_company_short, $country_code);
        $offerings = BOM::Product::ContractFinder::Basic::decorate($deco_args);
    }

    return {
        available    => $offerings,
        hit_count    => scalar(@$offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

sub _get_basic_offerings {
    my ($symbol, $landing_company_short, $country_code) = @_;

    $landing_company_short //= 'virtual';
    my $landing_company = LandingCompany::Registry::get($landing_company_short);
    my $offerings_obj   = $landing_company->basic_offerings_for_country($country_code, BOM::Config::Runtime->instance->get_offerings_config);

    return [$offerings_obj->query({underlying_symbol => $symbol})];
}

has _trading_calendar => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_trading_calendar',
);

sub _build_trading_calendar {
    my $self = shift;

    my $cr = BOM::Config::Chronicle::get_chronicle_reader($self->for_date);
    return Quant::Framework->new->trading_calendar($cr, $self->for_date);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package BOM::Product::ContractFinder;

use Moose;
use Date::Utility;
use Quant::Framework;
use LandingCompany::Registry;

use BOM::Product::ContractFinder::Basic;
use BOM::Product::ContractFinder::MultiBarrier;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);

has for_date => (
    is      => 'ro',
    default => undef,
);

sub multi_barrier_contracts_for {
    my ($self, $args) = @_;

    $args->{product_type} = 'multi_barrier';
    return $self->_get_contracts($args);
}

sub multi_barrier_contracts_by_category_for {
    my ($self, $args) = @_;

    my $contracts = $self->multi_barrier_contracts_for($args)->{available};
    my %by_contract_category;
    foreach my $param (@$contracts) {
        my $contract_category = $param->{contract_category};
        my $key               = $param->{trading_period}{date_start}{epoch} . '-' . $param->{trading_period}{date_expiry}{epoch};
        next if $by_contract_category{$contract_category}{$key};
        $by_contract_category{$contract_category}{$key}{available_barriers} = $param->{available_barriers};
    }

    return \%by_contract_category;
}

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

    my $date = $self->for_date // Date::Utility->new;
    my $underlying = create_underlying($args->{symbol}, $self->for_date);
    my $exchange   = $underlying->exchange;
    my $calendar   = $self->_trading_calendar;

    my ($offerings, $open, $close) = ([]);
    if ($calendar->trades_on($exchange, $date)) {
        $open = $calendar->opening_on($exchange, $date)->epoch;
        $close = $calendar->closing_on($exchange, $date)->epoch;
    }

    my $deco_args = {
        underlying => $underlying,
        calendar   => $calendar,
        date       => $date
    };
    if ($product_type eq 'basic') {
        $deco_args->{offerings} = _get_basic_offerings($symbol, $landing_company_short, $country_code);
        $offerings = BOM::Product::ContractFinder::Basic::decorate($deco_args);
    } elsif ($product_type eq 'multi_barrier') {
        $deco_args->{offerings} = _get_multi_barrier_offerings($symbol, $landing_company_short, $country_code);
        $offerings = BOM::Product::ContractFinder::MultiBarrier::decorate($deco_args);
    }

    return {
        available    => $offerings,
        hit_count    => scalar(@$offerings),
        open         => $open,
        close        => $close,
        feed_license => $underlying->feed_license
    };
}

sub _get_multi_barrier_offerings {
    my ($symbol, $landing_company_short, $country_code) = @_;

    $landing_company_short //= 'svg';
    my $landing_company = LandingCompany::Registry::get($landing_company_short);
    my $offerings_obj = $landing_company->multi_barrier_offerings_for_country($country_code, BOM::Config::Runtime->instance->get_offerings_config);

    my @offerings = map { $offerings_obj->query($_) } ({
            expiry_type       => 'daily',
            barrier_category  => 'euro_non_atm',
            contract_category => 'endsinout',
            underlying_symbol => $symbol,
        },
        {
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => 'euro_non_atm',
            contract_category => 'callput',
            underlying_symbol => $symbol,
        },
        {
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => 'euro_non_atm',
            contract_category => 'callputequal',
            underlying_symbol => $symbol,
        },
        {
            expiry_type       => 'daily',
            barrier_category  => 'american',
            contract_category => ['touchnotouch', 'staysinout'],
            underlying_symbol => $symbol,
        });

    return [map { $_->{barriers} = Finance::Contract::Category->new($_->{contract_category})->two_barriers ? 2 : 1; $_ } @offerings];
}

sub _get_basic_offerings {
    my ($symbol, $landing_company_short, $country_code) = @_;

    $landing_company_short //= 'svg';
    my $landing_company = LandingCompany::Registry::get($landing_company_short);
    my $offerings_obj = $landing_company->basic_offerings_for_country($country_code, BOM::Config::Runtime->instance->get_offerings_config);

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

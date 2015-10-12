package BOM::MarketData::ExchangeConfig;

use 5.010;
use Moose;
use List::MoreUtils qw( uniq );

has symbol => (
    is => 'ro',

);

has _data_location => (
    is      => 'ro',
    default => 'exchange_config',
);

has _document_content => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__document_content {
    my $self = shift;

    my $args = {
        symbol                   => $self->symbol,
        recorded_date            => $self->recorded_date->datetime_iso8601,
        delay_amount             => $self->delay_amount,
        offered                  => $self->offered,
        display_name             => $self->display_name,
        trading_timezone         => $self->trading_timezone,
        currency                 => $self->currency,
        holidays                 => $self->holidays,
        market_times             => $self->market_times,
        tenfore_trading_timezone => $self->tenfore_trading_timezone,
        open_on_weekends         => $self->open_on_weekends,
        bloomberg_calendar_code  => $self->bloomberg_calendar_code,
    };

    return $args;
}

with 'BOM::MarketData::Role::VersionedSymbolData';

has recorded_date => (
    is      => 'ro',
    lazy    => 1,
    isa     => 'Date::Utility',
    default => sub { Date::Utility->new },
);

has [
    qw(delay_amount offered display_name trading_timezone currency holidays market_times tenfore_trading_timezone open_on_weekends bloomberg_calendar_code)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

sub _build_delay_amount {
    my $self = shift;

    return $self->document->{'delay_amount'};
}

sub _build_offered {
    my $self = shift;

    return $self->document->{'offered'};
}

sub _build_display_name {
    my $self = shift;

    return $self->document->{'display_name'};
}

sub _build_trading_timezone {
    my $self = shift;

    return $self->document->{'trading_timezone'};
}

sub _build_currency {
    my $self = shift;

    return $self->document->{'currency'};
}

sub _build_holidays {
    my $self = shift;

    return $self->document->{'holidays'};
}

sub _build_market_times {
    my $self = shift;

    return $self->document->{'market_times'};
}

sub _build_tenfore_trading_timezone {
    my $self = shift;

    return $self->document->{'tenfore_trading_timezone'};
}

sub _build_open_on_weekends {
    my $self = shift;

    return $self->document->{'open_on_weekends'};
}

sub _build_bloomberg_calendar_code {
    my $self = shift;

    return $self->document->{'bloomberg_calendar_code'};
}

=head1 get_parameters

BOM::MarketData::ExchangeConfig->new({symbol => $symbol})->get_parameters;

Return reference to hash with parameters for given symbol.

=cut

sub get_parameters {
    my $self = shift;

    return $self->document;
}

=head1 get_symbol_for

Return the exchange symbol which contain either the relevant bloomberg_calendar_code or bloomberg_country_code

=cut

sub get_symbol_for {
    my ($self, %args) = @_;

    my @docs;

    my $params = {
        key => [$args{'bloomberg_calendar_code'}],
    };

    foreach my $exchange (@{$self->_couchdb->view("by_bloomberg_calendar_code", $params)}) {

        if ($exchange !~ /^(\w{2,9})$/ and $exchange ne 'NASDAQ_INDEX') { next; }

        my $symbol = $self->_couchdb->document($exchange)->{symbol};

        push @docs, $symbol;

    }

    return @docs;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package BOM::MarketData::CurrencyConfig;

use Moose;

has symbol => (
    is => 'ro',
);

has _data_location => (
    is      => 'ro',
    default => 'currency_config',
);

has _document_content => (
    is         => 'ro',
    lazy_build => 1,
);

has currency_list => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub {
        [
            'AUD', 'BRL', 'CAD', 'CHF', 'CNY', 'CZK', 'EUR', 'GBP', 'HKD', 'IDR', 'INR', 'JPY',
            'KRW', 'MXN', 'NOK', 'NZD', 'PLN', 'RUB', 'SEK', 'SGD', 'USD', 'XAG', 'XAU', 'ZAR'
        ];
    },

);

sub _build__document_content {
    my $self = shift;

    my $args = {
        symbol                              => $self->symbol,
        recorded_date                       => $self->recorded_date->datetime_iso8601,
        holidays                            => $self->holidays,
        bloomberg_country_code              => $self->bloomberg_country_code,
        daycount                            => $self->daycount,
        bloomberg_interest_rates_tickerlist => $self->bloomberg_interest_rates_tickerlist,
        bloomberg_calendar_code             => $self->bloomberg_calendar_code,
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

has [qw(holidays bloomberg_country_code daycount bloomberg_interest_rates_tickerlist bloomberg_calendar_code)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_holidays {
    my $self = shift;

    return $self->document->{'holidays'};
}

sub _build_bloomberg_country_code {
    my $self = shift;

    return $self->document->{'bloomberg_country_code'};
}

sub _build_daycount {
    my $self = shift;

    return $self->document->{'daycount'};
}

sub _build_bloomberg_interest_rates_tickerlist {
    my $self = shift;

    return $self->document->{'bloomberg_interest_rates_tickerlist'};
}

sub _build_recorded_date {
    my $self = shift;

    return $self->document->{'recorded_date'};
}

sub _build_bloomberg_calendar_code {
    my $self = shift;

    return $self->document->{'bloomberg_calendar_code'};
}

=head1 get_parameters

BOM::MarketData::CurrencyConfig->new({symbol => $symbol})->get_parameters;

Return reference to hash with parameters for given symbol.

=cut

sub get_parameters {
    my $self = shift;

    return $self->document;
}

=head1 get_symbol_for

Return the currency symbol which contain either the relevant bloomberg_calendar_code or bloomberg_country_code

=cut

sub get_symbol_for {
    my ($self, %args) = @_;

    my ($view, $bb_symbol, $params);
    my @docs;
    my @EU_country_code = ("BE", "CC", "EE", "FI", "FR", "GE", "GR", "IR", "IT", "MB", "NE", "PO", "SO", "SP", "SV", "TE", "AS");

    if ($args{'bloomberg_calendar_code'}) {

        $view      = 'by_bloomberg_calendar_code';
        $bb_symbol = $args{'bloomberg_calendar_code'};
        $params    = {
            key => [$bb_symbol],
        };

    } elsif ($args{'bloomberg_country_code'}) {

        $view      = 'by_bloomberg_country_code';
        $bb_symbol = $args{'bloomberg_country_code'};

        if (grep { $_ eq $bb_symbol } @EU_country_code) {
            return ('EU');
        }
        $params = {
            key => [[$bb_symbol]],
        };

    }
    foreach my $currency (@{$self->_couchdb->view($view, $params)}) {
        if ($currency !~ /^(\w\w\w)$/) { next; }

        my $symbol = $self->_couchdb->document($currency)->{symbol};
        push @docs, $symbol;
    }

    return @docs;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package SetupDatasetTestFixture;

use Moose;
use namespace::autoclean;
use Carp;

use Date::Utility;
use BOM::MarketData qw(create_underlying);
use Quant::Framework;
use BOM::Config::Chronicle;
use BOM::Test::Data::Utility::FeedTestDatabase;

=head1 original_spot

The original spot values in redis

=cut

has original_spot => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

=head1 original_rates

The original rates on Chronicle

=cut

has original_rates => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

=head1 setup_test_fixture

USAGE:

    my $fixture = SetupDatasetTestFixture->new

    $fixture->setup_test_fixture(underlying => $underlying , rates => $rates);
    $fixture->setup_test_fixture(underlying => $underlying , spot => $spot);
    $fixture->setup_test_fixture(underlying => $underlying , spot => $spot, rates => $rates, date => $date);

=cut

sub setup_test_fixture {
    my ($self, $args) = @_;

    croak "Underlying is not specified" if not $args->{underlying};
    my $underlying =
        (ref $args->{underlying} eq 'Quant::Framework::Underlying')
        ? $args->{underlying}
        : create_underlying($args->{underlying});
    if ($args->{rates}) {
        $self->_setup_rates($underlying, $args->{rates}, $args->{date});
    }

    if ($args->{spot}) {
        $self->_setup_spot($underlying, $args->{spot}, $args->{date});
    }

    return;
}

sub _setup_spot {
    my ($self, $underlying, $spot, $date) = @_;

    $date = (defined $date) ? $date : Date::Utility->new();
    $date =
        (ref $date eq 'Date::Utility')
        ? $date
        : Date::Utility->new($date);

    my $underlying_symbol = $underlying->symbol;

    my $default_data = $underlying->spot_tick;
    $self->original_spot->{$underlying_symbol} = $default_data
        if not exists $self->original_spot->{$underlying_symbol};

    my $values = {
        quote      => $spot,
        epoch      => $date->epoch,
        underlying => $underlying_symbol,
    };

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick($values);
    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick($values);

    return;
}

sub _setup_rates {
    my ($self, $underlying, $rates, $date) = @_;

    $date //= Date::Utility->new;
    $date =
        (ref $date eq 'Date::Utility')
        ? $date
        : Date::Utility->new($date);

    my $asset           = $underlying->asset;
    my $quoted_currency = $underlying->quoted_currency;
    if ($underlying->rate_to_imply eq $quoted_currency->symbol) {
        $quoted_currency = Quant::Framework::InterestRate->new(
            symbol           => $quoted_currency->symbol,
            rates            => $rates->{quoted_currency_rate},
            recorded_date    => $date,
            type             => 'implied',
            implied_from     => $asset->symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $quoted_currency->save;
    } else {
        $quoted_currency = Quant::Framework::InterestRate->new(
            symbol           => $quoted_currency->symbol,
            rates            => $rates->{quoted_currency_rate},
            recorded_date    => $date,
            type             => 'market',
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $quoted_currency->save;
    }

    if ($underlying->rate_to_imply eq $asset->symbol) {
        $asset = Quant::Framework::InterestRate->new(
            symbol           => $asset->symbol,
            rates            => $rates->{asset_rate}->{continuous},
            recorded_date    => $date,
            type             => 'implied',
            implied_from     => $quoted_currency->symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $asset->save;
    } else {
        if ($underlying->market->name eq 'indices') {
            $asset = Quant::Framework::Asset->new(
                symbol           => $asset->symbol,
                rates            => $rates->{asset_rate}->{continuous},
                recorded_date    => $date,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            );
        } else {
            $asset = Quant::Framework::InterestRate->new(
                symbol           => $asset->symbol,
                rates            => $rates->{asset_rate}->{continuous},
                recorded_date    => $date,
                type             => 'market',
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            );
        }
        $asset->save;
    }

    $asset->clear_rates;
    $quoted_currency->clear_rates;

    return;
}

=head1 reset_spot_and_rates_for

Resets underlying specific data to its original values

=cut

sub reset_spot_and_rates_for {
    my ($self, $underlying) = @_;

    $self->_reset_spot($underlying);
    $self->_reset_rates($underlying);

    return;
}

sub _reset_spot {
    my ($self, $underlying) = @_;

    my $reset_data = $self->original_spot->{$underlying->symbol};
    return if not $reset_data;
    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick($reset_data->as_hash);

    return;
}

sub _reset_rates {
    my ($self, $underlying) = @_;

    my $reset_data = $self->original_rates->{$underlying->symbol};
    return if not $reset_data;

    my ($current_quoted_currency_data, $current_asset_data);
    if ($underlying->rate_to_imply eq $underlying->quoted_currency->symbol) {
        $current_quoted_currency_data = Quant::Framework::InterestRate->new(
            symbol           => $underlying->quoted_currency->symbol,
            rates            => $reset_data->{quoted_currency},
            recorded_date    => Date::Utility->new,
            type             => 'implied',
            implied_from     => $underlying->asset->symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $current_quoted_currency_data->save;

    } else {

        $current_quoted_currency_data = Quant::Framework::InterestRate->new(
            symbol           => $underlying->quoted_currency->symbol,
            rates            => $reset_data->{quoted_currency},
            recorded_date    => Date::Utility->new,
            type             => 'market',
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),

        );
        $current_quoted_currency_data->save;

    }

    if ($underlying->rate_to_imply eq $underlying->asset->symbol) {
        $current_asset_data = Quant::Framework::InterestRate->new(
            symbol           => $underlying->asset->symbol,
            rates            => $reset_data->{asset},
            recorded_date    => Date::Utility->new,
            type             => 'implied',
            implied_from     => $underlying->quoted_currency->symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $current_asset_data->save;

    } else {

        $current_asset_data = Quant::Framework::InterestRate->new(
            symbol           => $underlying->asset->symbol,
            rates            => $reset_data->{asset},
            recorded_date    => Date::Utility->new,
            type             => 'market',
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        $current_asset_data->save;

    }
    return;
}

__PACKAGE__->meta->make_immutable;
1;

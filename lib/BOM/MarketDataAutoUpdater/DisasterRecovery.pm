package BOM::MarketDataAutoUpdater::DisasterRecovery;

use strict;
use warnings;

use Moo;

use Date::Utility;
use Try::Tiny;
use LandingCompany::Registry;
use JSON::MaybeXS;
use Finance::Asset;

use BOM::Config::Runtime;
use BOM::Config::Chronicle;

use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use Quant::Framework::Asset;
use Quant::Framework::InterestRate;
use Quant::Framework::ImpliedRate;
use Quant::Framework::Calendar;
use Quant::Framework::CorrelationMatrix;

=head2 db

Default to chronicle database since we only have one data source.

=cut

has _db => (
    is      => 'ro',
    default => sub {
        return BOM::Config::Chronicle::dbic();
    });

has _chronicle_reader => (
    is      => 'ro',
    default => sub {
        return BOM::Config::Chronicle::get_chronicle_reader(1);
    },
);

has _chronicle_writer => (
    is      => 'ro',
    default => sub {
        return BOM::Config::Chronicle::get_chronicle_writer();
    },
);

has [qw(_exceptions _not_found)] => (
    is      => 'ro',
    default => sub { [] },
);

my $archive          = 0;
my $suppress_publish = 1;
my $json             = JSON::MaybeXS->new;

=head2 symbols

Symbols to recover

=cut

sub _symbols {
    my ($self, $name) = @_;

    my $sql = q{
        SELECT DISTINCT name FROM chronicle WHERE category=? AND timestamp >= 'today'::TIMESTAMP - '30 days'::INTERVAL;
    };

    my $output = $self->_db->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->bind_param(1, $name);
            $sth->execute;

            return $sth->fetchall_arrayref();
        });

    return [map { @$_ } @$output];
}

sub run {
    my $self = shift;

    $self->_recover_app_settings();
    $self->_recover_economic_events();
    $self->_recover_volsurface();
    $self->_recover_interest_rate();
    $self->_recover_dividend();
    $self->_recover_holiday();
    $self->_recover_correlation_matrix();
    $self->_recover_predefined_parameters();

    if (my @e = @{$self->_exceptions}) {
        print "### EXCEPTIONS ###\n";
        print join "\n", @e;
    }

    if (my @m = @{$self->_not_found}) {
        print "### MISSING DATA ###\n";
        print join "\n", @m;
    }

    return;
}

sub _recover_app_settings {
    my $self = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    my $sql        = q{
        SELECT value FROM chronicle WHERE category='app_settings' AND name=? ORDER BY timestamp DESC limit 1;
    };

    foreach my $key ($app_config->all_keys, 'binary') {
        my $output = $self->_db->run(
            fixup => sub {
                my $sth = $_->prepare($sql);
                $sth->bind_param(1, $key);
                $sth->execute();

                return $sth->fetchall_arrayref();
            },
        );
        next unless @$output;
        $self->_chronicle_writer->set('app_settings', $key, $json->decode($output->[0][0]), Date::Utility->new, $archive, $suppress_publish);
    }

    return;
}

sub _recover_predefined_parameters {
    my $self = shift;

    my $date = Date::Utility->new;
    my $name = 'predefined_parameters';
    foreach my $symbol (@{$self->_symbols($name)}) {
        if ($self->_chronicle_reader->get($name, $symbol)) {
            next;
        }

        my $data = $self->_chronicle_reader->get_for($name, $symbol, $date);
        unless ($data) {
            push @{$self->_not_found}, 'Data not found for ' . $name . '::' . $symbol;
            next;
        }

        $self->_chronicle_writer->set($name, $symbol, $data, $date, $archive, $suppress_publish);
    }

    return;
}

sub _recover_correlation_matrix {
    my $self = shift;

    try {
        Quant::Framework::CorrelationMatrix->new(
            symbol           => 'indices',
            for_date         => Date::Utility->new,
            chronicle_reader => $self->_chronicle_reader,
            chronicle_writer => $self->_chronicle_writer
        )->save($archive, $suppress_publish);
    }
    catch {
        push @{$self->_exceptions}, 'Exception thrown while recovering correlation_matrices::indices';
    };

    return;
}

sub _recover_holiday {
    my $self = shift;

    try {
        foreach my $d (
            ['holidays',        'holidays'],
            ['holidays',        'manual_holidays'],
            ['partial_trading', 'early_closes'],
            ['partial_trading', 'manual_early_closes'])
        {
            Quant::Framework::Calendar->new(
                calendar_name    => $d->[0],
                type             => $d->[1],
                for_date         => Date::Utility->new,
                chronicle_reader => $self->_chronicle_reader,
                chronicle_writer => $self->_chronicle_writer
            )->save($archive, $suppress_publish);
        }
    }
    catch {
        push @{$self->_exceptions}, 'Exception thrown while recovering holidays';
    };

    return;
}

sub _recover_dividend {
    my $self = shift;

    my $name = 'dividends';
    foreach my $symbol (@{$self->_symbols($name)}) {
        if ($self->_chronicle_reader->get($name, $symbol)) {
            next;
        }

        try {
            Quant::Framework::Asset->new(
                for_date         => Date::Utility->new,
                chronicle_reader => $self->_chronicle_reader,
                chronicle_writer => $self->_chronicle_writer,
                symbol           => $symbol,
            )->save($archive, $suppress_publish);
        }
        catch {
            push @{$self->_exceptions}, 'Exception thrown while recovering ' . $name . '::' . $symbol;
        };
    }

    return;
}

sub _recover_interest_rate {
    my $self = shift;

    my $name = 'interest_rates';
    foreach my $symbol (@{$self->_symbols($name)}) {
        if ($self->_chronicle_reader->get($name, $symbol)) {
            next;
        }

        my $class = $symbol =~ /-/ ? 'Quant::Framework::ImpliedRate' : 'Quant::Framework::InterestRate';
        try {
            $class->new(
                for_date         => Date::Utility->new,
                chronicle_reader => $self->_chronicle_reader,
                chronicle_writer => $self->_chronicle_writer,
                symbol           => $symbol,
            )->save($archive, $suppress_publish);
        }
        catch {
            push @{$self->_exceptions}, 'Exception thrown while recovering ' . $name . '::' . $symbol;
        };
    }

    return;
}

sub _recover_volsurface {
    my $self = shift;

    my $offerings    = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my $params       = Finance::Asset->all_parameters;
    my @quanto       = grep { $params->{$_}->{quanto_only} } keys %$params;
    my %offered_list = map { $_ => 1 } ($offerings->values_for_key('underlying_symbol'), @quanto);
    my $name         = 'volatility_surfaces';
    foreach my $symbol (@{$self->_symbols($name)}) {
        if ($self->_chronicle_reader->get($name, $symbol) or not $offered_list{$symbol}) {
            next;
        }

        my $underlying = Quant::Framework::Underlying->new($symbol);
        my $vst        = $underlying->volatility_surface_type;
        next if $vst !~ /(?:delta|moneyness)/;    # don't do anything if it is not moneyness or delta
        my $class = $vst eq 'delta' ? 'Quant::Framework::VolSurface::Delta' : 'Quant::Framework::VolSurface::Moneyness';
        try {
            $class->new(
                for_date         => Date::Utility->new,
                chronicle_reader => $self->_chronicle_reader,
                chronicle_writer => $self->_chronicle_writer,
                underlying       => $underlying,
            )->save($archive, $suppress_publish);
        }
        catch {
            push @{$self->_exceptions}, 'Exception thrown while recovering ' . $name . '::' . $symbol;
        };
    }

    return;
}

sub _recover_economic_events {
    my $self = shift;

    my $date    = Date::Utility->new;
    my $ee_name = 'economic_events';
    # populate the raw economic events
    unless ($self->_chronicle_reader->get($ee_name, $ee_name)) {
        my $ee_data = $self->_chronicle_reader->get_for($ee_name, $ee_name, $date);
        $self->_chronicle_writer->set($ee_name, $ee_name, $ee_data, $date, $archive, $suppress_publish);
    }

    my $name = 'economic_events_variance';
    # populates the calculated economic events variance
    foreach my $symbol (@{$self->_symbols($name)}) {
        if ($self->_chronicle_reader->get($name, $symbol)) {
            next;
        }

        my $data = $self->_chronicle_reader->get_for($name, $symbol, $date);
        unless ($data) {
            push @{$self->_not_found}, 'Data not found for ' . $name . '::' . $symbol;
            next;
        }

        $self->_chronicle_writer->set($name, $symbol, $data, $date, $archive, $suppress_publish);
    }

    return;
}

1;

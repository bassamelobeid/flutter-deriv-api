package BOM::Backoffice::CustomCommissionTool;

use strict;
use warnings;

use BOM::Backoffice::Request;
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use JSON qw(to_json);
use Try::Tiny;
use BOM::Product::Pricing::Engine::Intraday::Forex;

my $static_config = {
    high => {
        cap_rate      => 0.3,
        floor_rate    => 0.1,
        center_offset => 0,
        width         => 0.5,
    },
    medium => {
        cap_rate      => 0.25,
        floor_rate    => 0.05,
        center_offset => 0,
        width         => 0.5,
    },
    default => {
        cap_rate      => '',
        floor_rate    => '',
        center_offset => '',
        width         => '',
    }};

sub generate_commission_form {
    my $url = shift;

    my @config = map { _get_info($_) } @{_qc()->get_config('commission')};
    return BOM::Backoffice::Request::template->process(
        'backoffice/custom_commission_form.html.tt',
        {
            upload_url    => $url,
            static_config => to_json($static_config),
            config        => to_json(\@config),
        },
    ) || die BOM::Backoffice::Request::template->error;
}

sub save_commission {
    my $args = shift;

    my $result = try {
        _get_info(_qc()->save_config('commission', $args));
    }
    catch {
        _err($_);
    };

    return $result;
}

sub delete_commission {
    my $name = shift;

    my $result = try {
        _qc()->delete_config('commission', $name);
    }
    catch {
        _err($_);
    };

    return $result;
}

sub get_chart_params {
    my $args = shift;

    my $result = try {
        my @data;
        my @delta;
        for (my $delta = 0; $delta <= 1; $delta += 0.05) {
            push @data, BOM::Product::Pricing::Engine::Intraday::Forex::calculate_commission($delta, $args);
            push @delta, $delta;
        }
        +{
            data  => \@data,
            delta => \@delta,
        };
    }
    catch {
        _err($_);
    };

    return $result;
}

sub _err {
    return {error => 'ERR: ' . shift};
}

sub _qc {
    return BOM::Platform::QuantsConfig->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
}

sub _get_info {
    my $config = shift;

    return {
        name => delete $config->{name},
        (contract_type     => ($config->{contract_type})     ? join(',', @{delete $config->{contract_type}})     : 'none'),
        (underlying_symbol => ($config->{underlying_symbol}) ? join(',', @{delete $config->{underlying_symbol}}) : 'none'),
        (currency_symbol   => ($config->{currency_symbol})   ? join(',', @{delete $config->{currency_symbol}})   : 'none'),
        config => $config,
    };
}

1;

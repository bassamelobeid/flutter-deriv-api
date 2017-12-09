package BOM::Backoffice::CustomCommissionTool;

use strict;
use warnings;

use BOM::Backoffice::Request;
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use JSON::MaybeXS;
use Try::Tiny;
use List::Util qw(max);
use BOM::Product::Pricing::Engine::Intraday::Forex;

my $static_config = {
    high => {
        cap_rate      => 0.3,
        floor_rate    => 0.1,
        centre_offset => 0,
        width         => 0.5,
        flat          => 0,
    },
    medium => {
        cap_rate      => 0.25,
        floor_rate    => 0.05,
        centre_offset => 0,
        width         => 0.5,
        flat          => 0,
    },
    none => {
        cap_rate      => '',
        floor_rate    => '',
        centre_offset => '',
        width         => '',
        flat          => '',
    },
};

my $json = JSON::MaybeXS->new;
sub generate_commission_form {
    my $url = shift;

    my @config = map { _get_info($_) } @{_qc()->get_config('commission')};
    return BOM::Backoffice::Request::template->process(
        'backoffice/custom_commission_form.html.tt',
        {
            upload_url    => $url,
            static_config => $json->encode($static_config),
            config        => $json->encode(\@config),
        },
    ) || die BOM::Backoffice::Request::template->error;
}

sub save_commission {
    my $args = shift;

    my $result = try {
        _break($args);
        my $config = _get_info(_qc()->save_config('commission', $args));
        $config;
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
        my %data;
        _break($args);
        foreach my $partition (@{$args->{partitions}}) {
            my ($start, $end) = split '-', $partition->{partition_range};
            for (my $delta = $start; $delta <= $end; $delta += 0.05) {
                $data{$delta} =
                    max($data{$delta} // 0, BOM::Product::Pricing::Engine::Intraday::Forex::calculate_event_adjustment($delta, $partition));
            }
        }

        my @delta = sort { $a <=> $b } keys %data;
        +{
            data  => [map { $data{$_} } @delta],
            delta => \@delta,
        };
    }
    catch {
        _err($_);
    };

    return $result;
}

sub _break {
    my $args = shift;

    my @to_break = qw(partition_range flat cap_rate floor_rate width centre_offset);
    my %hash = map { $_ => [split ',', delete $args->{$_}] } @to_break;
    my @partitions;
    my $number_of_partitions = scalar(@{$hash{partition_range}});
    for (1 .. $number_of_partitions) {
        push @partitions, +{map { $_ => (shift @{$hash{$_}} // die 'unmatched partition ' . $_) } @to_break};
    }

    $args->{partitions} = \@partitions;
    return $args;
}

sub _err {
    return {error => 'ERR: ' . shift};
}

sub _qc {
    return BOM::Platform::QuantsConfig->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );
}

sub _get_info {
    my $config = shift;

    return {
        name       => $config->{name},
        start_time => Date::Utility->new($config->{start_time})->datetime,
        end_time   => Date::Utility->new($config->{end_time})->datetime,
        (bias => $config->{bias} ? $config->{bias} : 'none'),
        (underlying_symbol => ($config->{underlying_symbol}) ? join(',', @{$config->{underlying_symbol}}) : 'none'),
        (currency_symbol   => ($config->{currency_symbol})   ? join(',', @{$config->{currency_symbol}})   : 'none'),
        config => $config->{partitions},
    };
}

1;

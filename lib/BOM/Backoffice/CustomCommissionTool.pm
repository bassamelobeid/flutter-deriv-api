package BOM::Backoffice::CustomCommissionTool;

use strict;
use warnings;

use BOM::Backoffice::Request;
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use JSON::MaybeXS;
use Try::Tiny;
use List::Util qw(max);

my $json = JSON::MaybeXS->new;

sub generate_commission_form {
    my $url = shift;

    my @config = map { _get_info($_) } @{_qc()->get_config('commission')};
    return BOM::Backoffice::Request::template->process(
        'backoffice/custom_commission_form.html.tt',
        {
            upload_url => $url,
            config     => $json->encode(\@config),
        },
    ) || die BOM::Backoffice::Request::template->error;
}

sub _check_value {
    my ($what, $args) = @_;

    return _err($what . '_max is not defined') unless exists $args->{$what . '_max'};

    my @to_compare = map { $args->{$what . $_} } grep { exists $args->{$what . $_} } qw(_max _3 _2 _1);

    return if scalar(@to_compare) < 2;

    for (my $i = 0; $i < $#to_compare; $i++) {
        if ($to_compare[$i] < $to_compare[$i + 1]) {
            return _err("$to_compare[$i] cannot be lower than $to_compare[$i+1]");
        }
    }

    return;
}

sub save_commission {
    my $args = shift;

    for (qw(ITM OTM)) {
        if (my $err = _check_value($_, $args)) {
            return $err;
        }
    }

    my $result = try {
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

    my %combined_commission = map { $_ => $config->{$_} } qw(ITM_1 ITM_2 ITM_3 atm OTM_1 OTM_2 OTM_3 OTM_max ITM_max);

    return {
        name       => $config->{name},
        start_time => Date::Utility->new($config->{start_time})->datetime,
        end_time   => Date::Utility->new($config->{end_time})->datetime,
        (bias => $config->{bias} ? $config->{bias} : 'none'),
        (underlying_symbol => ($config->{underlying_symbol}) ? join(',', @{$config->{underlying_symbol}}) : 'none'),
        (currency_symbol   => ($config->{currency_symbol})   ? join(',', @{$config->{currency_symbol}})   : 'none'),
        config => \%combined_commission,
    };
}

1;

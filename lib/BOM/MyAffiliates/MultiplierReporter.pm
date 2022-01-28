package BOM::MyAffiliates::MultiplierReporter;

=head1 NAME

BOM::MyAffiliates::MultiplierReporter

=head1 DESCRIPTION

This class generates clients' multiplier contracts trading commission reports;
=head1 SYNOPSIS

    use BOM::MyAffiliates::MultiplierReporter;

    my $reporter = BOM::MyAffiliates::MultiplierReporter->new(
        brand           => Brands->new(),
        processing_date => Date::Utility->new('18-Aug-10'));

    $reporter->activity();

=cut

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Text::CSV;
use Date::Utility;
use File::SortedSeek qw(numeric get_between);
use Format::Util::Numbers qw(formatnumber);
use ExchangeRates::CurrencyConverter qw(in_usd);
use YAML::XS qw(LoadFile);
use BOM::Config::Runtime;
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use BOM::User::Client;

use constant HEADERS => qw(
    date client_loginid trade_commission commission
);

has '+include_headers' => (
    default => 1,
);

=head2 activity

    $reporter->activity();

    Produce a nicely formatted CSV output adjusted to USD.
=cut

sub activity {
    my $self = shift;

    my $when = $self->processing_date;

    my $result = $self->computation();

    my @output = ();

    push @output, $self->format_data($self->headers_data()) if ($self->include_headers and keys %{$result});

    foreach my $loginid (sort keys %{$result}) {
        next if $self->is_broker_code_excluded($loginid);

        my $csv           = Text::CSV->new;
        my @output_fields = (
            $when->date_yyyymmdd,
            $self->prefix_field($loginid),
            formatnumber('amount', 'USD', $result->{$loginid}{trade_commission}),
            formatnumber('amount', 'USD', $result->{$loginid}{commission}));

        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

sub computation {
    my $self = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $trade_commission = {
        financial     => $app_config->get('quants.multiplier_affiliate_commission.financial'),
        non_financial => $app_config->get('quants.multiplier_affiliate_commission.non_financial')};

    my $when = $self->processing_date;

    my $apps_by_brand = $self->get_apps_by_brand();
    my $commission    = $self->database_mapper()->get_multiplier_commission({
        date         => $when->date_yyyymmdd,
        include_apps => $apps_by_brand->{include_apps},
        exclude_apps => $apps_by_brand->{exclude_apps},
    });

    my $result = {};

    my @info_list = qw(loginid market_type underlying_symbol is_cancellation value);
    my $info_map;

    foreach my $info (@$commission) {
        $info_map = {map { $info_list[$_] => @$info[$_] } 0 .. (scalar @$info - 1)};
        if ($info_map->{is_cancellation} == 0) {
            $result->{$info_map->{loginid}}{trade_commission} += $info_map->{value};
            $result->{$info_map->{loginid}}{commission}       += $info_map->{value} * $trade_commission->{$info_map->{market_type}};
        } else {
            my $quant_config = BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());
            my $commission_rate =
                $quant_config->get_multiplier_config(BOM::User::Client->new({loginid => $info_map->{loginid}})->landing_company->short,
                $info_map->{underlying_symbol})->{cancellation_commission};
            my $cancellation_commission = $info_map->{value} * $commission_rate;

            $result->{$info_map->{loginid}}{trade_commission} += $cancellation_commission;
            $result->{$info_map->{loginid}}{commission}       += $cancellation_commission * $trade_commission->{$info_map->{market_type}};
        }

    }
    return $result;
}

sub output_file_prefix {
    return 'multiplier_';
}

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

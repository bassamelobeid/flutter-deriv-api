package BOM::MyAffiliates::AccumulatorReporter;

=head1 NAME

BOM::MyAffiliates::AccumulatorReporter

=head1 DESCRIPTION

This class generates clients' accumulator contracts trading commission reports

=head1 SYNOPSIS

    use BOM::MyAffiliates::AccumulatorReporter;

    my $reporter = BOM::MyAffiliates::AccumulatorReporter->new(
        brand           => Brands->new(),
        processing_date => Date::Utility->new('18-Aug-10'));

    $reporter->activity();

=cut

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Text::CSV;
use Date::Utility;
use Format::Util::Numbers            qw(financialrounding);
use ExchangeRates::CurrencyConverter qw(in_usd);
use Finance::Contract::Longcode      qw(shortcode_to_parameters);
use Finance::Underlying;
use BOM::Config::Runtime;

=head2 HEADERS

defining headers to be used in the csv file

=cut

use constant HEADERS => qw(
    date client_loginid trade_commission commission exchange_rate
);

=head2 include_headers

Including headers.

=cut

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

    my $apps_by_brand = $self->get_apps_by_brand();

    my $activity = $self->database_mapper()->get_clients_activity({
        date              => $when->date_yyyymmdd,
        only_authenticate => 'false',
        broker_code       => undef,
        include_apps      => $apps_by_brand->{include_apps},
        exclude_apps      => $apps_by_brand->{exclude_apps},
    });

    my @output          = ();
    my %conversion_hash = ();

    push @output, $self->format_data($self->headers_data()) if ($self->include_headers and keys %{$result});

    foreach my $loginid (sort keys %{$result}) {
        next if $self->is_broker_code_excluded($loginid);

        my $currency = $activity->{$loginid}->{currency};

        # this is for optimization else we would need to call in_usd for each record
        # this only calls if currency is not in hash
        $conversion_hash{$currency} = in_usd(1, $currency) unless exists $conversion_hash{$currency};

        my $csv           = Text::CSV->new;
        my @output_fields = (
            $when->date_yyyymmdd,
            $self->prefix_field($loginid),
            financialrounding('amount', 'USD', $result->{$loginid}->{trade_commission} * $conversion_hash{$currency}),
            financialrounding('amount', 'USD', $result->{$loginid}->{commission} * $conversion_hash{$currency}));

        if ($currency eq 'USD') {
            push @output_fields, financialrounding('amount', 'USD', 1);
        } else {
            # we need to convert other currencies to USD as required
            # by myaffiliates system
            push @output_fields, financialrounding('amount', 'USD', $conversion_hash{$currency});
        }

        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

=head2 computation

    $reporter->computation();

    Calculates affiliate commission based on the parameters retrieved from contract's short_code.

=cut

sub computation {
    my $self = shift;

    my $app_config    = BOM::Config::Runtime->instance->app_config;
    my $when          = $self->processing_date;
    my $apps_by_brand = $self->get_apps_by_brand();

    my $commission = $self->database_mapper()->get_accumulator_commission({
        date         => $when->date_yyyymmdd,
        include_apps => $apps_by_brand->{include_apps},
        exclude_apps => $apps_by_brand->{exclude_apps},
    });

    my $result = {};
    my $info_map;
    my $commission_ratio;

    foreach my $info (@$commission) {
        $info_map = {
            loginid    => @$info[0],
            currency   => @$info[1],
            short_code => @$info[2]};
        my $contract_params = shortcode_to_parameters($info_map->{short_code});
        my $market_type     = Finance::Underlying->by_symbol($contract_params->{underlying})->market_type;

        if ($market_type eq "non_financial") {
            $commission_ratio = $app_config->get('quants.accumulator.affiliate_commission.non_financial');
        } else {
            $commission_ratio = $app_config->get('quants.accumulator.affiliate_commission.financial');
        }

        # growth_start_step = (tick number from which growth starts to grow) - 1
        my $trade_commission_value =
            $contract_params->{amount} * ((1 + $contract_params->{growth_rate})**($contract_params->{growth_start_step}) - 1);

        if (exists $result->{$info_map->{loginid}}) {
            $trade_commission_value += $result->{$info_map->{loginid}}->{trade_commission};
            $result->{$info_map->{loginid}} = {
                trade_commission => $trade_commission_value,
                commission       => $trade_commission_value * $commission_ratio,
                currency         => $info_map->{currency}};
        } else {
            $result->{$info_map->{loginid}} = {
                trade_commission => $trade_commission_value,
                commission       => $trade_commission_value * $commission_ratio,
                currency         => $info_map->{currency}};
        }

    }

    return $result;
}

=head2 output_file_prefix

    $reporter->output_file_prefix;

    indicates the prefix for the output file. 

=cut

sub output_file_prefix {
    return 'accumulator_';
}

=head2 headers

    $reporter->headers;

    returns the list of headers. 

=cut

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

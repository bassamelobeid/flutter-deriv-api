package BOM::MyAffiliates::LookbackReporter;

=head1 NAME

BOM::MyAffiliates::LookbackReporter

=head1 DESCRIPTION

This class generates lookback turnover commission report for clients.
It includes contract login id, stake price, lookback commission

=head1 SYNOPSIS

    use BOM::MyAffiliates::LookbackReporter;
    my $reporter = BOM::MyAffiliates::LookbackReporter->new(
        brand           => Brands->new(),
        processing_date => Date::Utility->new('18-Aug-10'));
    $reporter->activity();

=cut

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Date::Utility;
use Text::CSV;
use File::SortedSeek                 qw/numeric get_between/;
use Format::Util::Numbers            qw/financialrounding/;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Config::Runtime;
use BOM::Config::QuantsConfig;

use constant HEADERS => qw(
    date client_loginid stake lookback_commission exchangerate
);

=head2 activity

$reporter->activity(); 

Produce a nicely formatted CSV output adjusted into USD

for the requested date formatted as follows:

Transaction date, Client loginid, stake price, lookback commission

=cut

sub activity {
    my $self = shift;

    my $when = $self->processing_date;

    my $apps_by_brand = $self->get_apps_by_brand();
    my $activity      = $self->database_mapper()->get_lookback_activity({
        date         => $self->processing_date->date_yyyymmdd,
        include_apps => $apps_by_brand->{include_apps},
        exclude_apps => $apps_by_brand->{exclude_apps},
    });

    my $stake_percentage_commission =
        BOM::Config::Runtime->instance->app_config->quants->commission->adjustment->lookback->stake_percentage_commission;
    my @output          = ();
    my %conversion_hash = ();
    push @output, $self->format_data($self->headers_data()) if ($self->include_headers and scalar @$activity);

    foreach my $obj (@$activity) {
        my $loginid  = $obj->[0];
        my $currency = $obj->[2];

        next if $self->is_broker_code_excluded($loginid);

        # this is for optimization else we would need to call in_usd for each record
        # this only calls if currency is not in hash
        $conversion_hash{$currency} = in_usd(1, $currency) unless exists $conversion_hash{$currency};

        my $csv           = Text::CSV->new;
        my @output_fields = (
            # transaction date
            $when->date_yyyymmdd,
            # loginid
            $self->prefix_field($loginid),
            # stake
            financialrounding('price', 'USD', $obj->[1]),
            # lookback_commission
            financialrounding('price', 'USD', $obj->[1] * $stake_percentage_commission));
        # exchange rate
        if ($currency eq 'USD') {
            push @output_fields, financialrounding('price', 'USD', 1);
        } else {
            # we need to convert other currencies to USD as required
            # by myaffiliates system
            push @output_fields, financialrounding('price', 'USD', $conversion_hash{$currency});
        }
        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

=head2 output_file_prefix

Add output file prefix for the report.

=cut

sub output_file_prefix {
    return 'lookback_';
}

=head2 headers

Return headers for lookback report.

=cut

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

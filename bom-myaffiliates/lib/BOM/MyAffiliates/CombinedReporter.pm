package BOM::MyAffiliates::CombinedReporter;

=head1 NAME

BOM::MyAffiliates::CombinedReporter

=head1 DESCRIPTION

This reporter generates clients' all contracts trading commission reports;
=head1 SYNOPSIS

    use BOM::MyAffiliates::CombinedReporter;

    my $reporter = BOM::MyAffiliates::CombinedReporter->new(
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
use BOM::Config::Runtime;

use BOM::MyAffiliates::MultiplierReporter;
use BOM::MyAffiliates::ContractsWithSpreadReporter;

use constant HEADERS => qw(
    date client_loginid multiplier_commission turbos_commission accumulator_commission vanilla_commission sharkfin_commission synthetic_bond_commission exchange_rate
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

    my $when  = $self->processing_date;
    my $brand = $self->brand;
    my %combined_data;
    my @contract_categories = qw(turbos accumulator vanilla);

    foreach my $contract_category ('multiplier', @contract_categories) {
        my $reporter;

        if ($contract_category eq 'multiplier') {
            $reporter = BOM::MyAffiliates::MultiplierReporter->new(
                processing_date => $when,
                brand           => $brand,
            );
        } else {
            $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
                processing_date   => $when,
                brand             => $brand,
                contract_category => $contract_category,
            );
        }

        my @csv_data = $reporter->activity();

        foreach my $csv_row (@csv_data) {
            my @lines = split /\n/, $csv_row;
            shift @lines if $lines[0] =~ /^date,client_loginid/;

            for my $line (@lines) {
                my ($date, $client_loginid, $trade_commission, $commission, $exchange_rate) = split /\s*,\s*/, $line;
                $combined_data{$date}{$client_loginid} //= {
                    multiplier_commission  => 0.00,
                    turbos_commission      => 0.00,
                    accumulator_commission => 0.00,
                    vanilla_commission     => 0.0
                };

                if ($commission) {
                    my $commission_type = $contract_category eq 'multiplier' ? 'multiplier_commission' : "${contract_category}_commission";
                    $combined_data{$date}{$client_loginid}{$commission_type} = $commission;
                }

                $combined_data{$date}{$client_loginid}{exchange_rate} = $exchange_rate;

            }
        }
    }

    my @output;
    push @output, $self->format_data($self->headers_data()) if $self->include_headers;

    my $csv = Text::CSV->new;
    my @output_fields;

    foreach my $date (sort keys %combined_data) {
        foreach my $client_loginid (sort keys %{$combined_data{$date}}) {
            my $data_ref = $combined_data{$date}{$client_loginid};

            @output_fields = (
                $date,
                $client_loginid,
                $data_ref->{multiplier_commission}     // 0.0,
                $data_ref->{turbos_commission}         // 0.0,
                $data_ref->{accumulator_commission}    // 0.0,
                $data_ref->{vanilla_commission}        // 0.0,
                $data_ref->{sharkfin_commission}       // 0.0,
                $data_ref->{synthetic_bond_commission} // 0.0,
                $data_ref->{exchange_rate});

            $csv->combine(@output_fields);
            push @output, $self->format_data($csv->string);
        }
    }

    return @output;
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

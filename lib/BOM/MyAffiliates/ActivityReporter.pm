package BOM::MyAffiliates::ActivityReporter;

=head1 NAME

BOM::MyAffiliates::ActivityReporter

=head1 DESCRIPTION

This class generates client trading activity reports, including turnover,
profit and loss, deposits and withdrawals.

=head1 SYNOPSIS

    use BOM::MyAffiliates::ActivityReporter;

    my $reporter = BOM::MyAffiliates::ActivityReporter->new(
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

use constant HEADERS => qw(
    date client_loginid company_profit_loss deposits turnover_ticktrade intraday_turnover other_turnover first_funded_date withdrawals first_funded_amount
);

has '+include_headers' => (
    default => 0,
);

=head2 activity

    $reporter->activity();

    Produce a nicely formatted CSV output adjusted to USD.
=cut

sub activity {
    my $self = shift;

    my $when = $self->processing_date;

    my $apps_by_brand = $self->get_apps_by_brand();
    my $activity      = $self->database_mapper()->get_clients_activity({
        date              => $when->date_yyyymmdd,
        only_authenticate => 'false',
        broker_code       => undef,
        include_apps      => $apps_by_brand->{include_apps},
        exclude_apps      => $apps_by_brand->{exclude_apps},
    });

    my @output          = ();
    my %conversion_hash = ();

    push @output, $self->headers_data() if ($self->include_headers and keys %{$activity});

    foreach my $loginid (sort keys %{$activity}) {

        next if $self->is_broker_code_excluded($loginid);

        my $currency = $activity->{$loginid}->{currency};

        # this is for optimization else we would need to call in_usd for each record
        # this only calls if currency is not in hash
        $conversion_hash{$currency} = in_usd(1, $currency) unless exists $conversion_hash{$currency};

        my $csv = Text::CSV->new;

        my $first_funded_date =
            $activity->{$loginid}->{'first_funded_date'} ? Date::Utility->new($activity->{$loginid}->{'first_funded_date'})->date_yyyymmdd : '';
        my @output_fields = ($when->date_yyyymmdd, $self->prefix_field($loginid));

        if ($currency eq 'USD') {
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{pnl});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{deposits});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{turnover_ticktrade});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{turnover_intradays});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{turnover_others});
            push @output_fields, $first_funded_date;
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{'withdrawals'});
            push @output_fields, formatnumber('amount', $currency, ($activity->{$loginid}->{'first_funded_amount'}) // 0);
        } else {
            # we need to convert other currencies to USD as required
            # by myaffiliates system
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{pnl});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{deposits});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_ticktrade});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_intradays});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_others});
            push @output_fields, $first_funded_date;
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{'withdrawals'});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * ($activity->{$loginid}->{'first_funded_amount'} // 0));
        }

        $csv->combine(@output_fields);
        push @output, $self->format_data($csv->string);
    }

    return @output;
}

sub output_file_prefix {
    return 'pl_';
}

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

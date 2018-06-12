package BOM::MyAffiliates::ActivityReporter;

=head1 NAME

BOM::MyAffiliates::ActivityReporter

=head1 DESCRIPTION

This class generates client trading activity reports, including turnover,
profit and loss, deposits and withdrawals.

=head1 SYNOPSIS

    use BOM::MyAffiliates::ActivityReporter;

    my $date = '18-Aug-10';

    my $reporter = BOM::MyAffiliates::ActivityReporter->new;
    $reporter->activity_for_date_as_csv($date);

=cut

use Moose;
use Text::CSV;
use Date::Utility;
use File::SortedSeek qw(numeric get_between);
use Format::Util::Numbers qw(formatnumber);
use Postgres::FeedDB::CurrencyConverter qw(in_USD);

use BOM::Database::DataMapper::MyAffiliates;

=head2 activity_for_date_as_csv

    $reporter->activity_for_date_as_csv('8-Sep-10');

    Produce a nicely formatted CSV output adjusted to USD
    for all other landing companies except Japan.
    (For Japan we need to send back in YEN only)

    Result is formatted to this form:

    Date, Client Loginid, company profit/loss from client, deposits,
    turnover_runbets, intraday turnover, other turnover, first funded date,
    withdrawals, first funded amount

=cut

sub activity_for_date_as_csv {
    my ($self, $date_selection, $cpa_type) = @_;

    return _generate_csv_output($date_selection, $cpa_type);
}

sub _generate_csv_output {
    my ($date_selected, $cpa_type) = @_;

    my $when = Date::Utility->new($date_selected);

    my $myaffiliates_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });

    $myaffiliates_data_mapper->db->dbic->run(ping => sub { $_->do("SET statement_timeout TO " . 900_000) });

    my $activity;
    if ($cpa_type) {
        $activity = $myaffiliates_data_mapper->get_clients_activity({
            'date'               => $when,
            'only_authenticated' => 1,
            'broker_code'        => 'MF'
        });
    } else {
        $activity = $myaffiliates_data_mapper->get_clients_activity({'date' => $when});
    }

    my @output;
    my %conversion_hash = ();

    foreach my $loginid (sort keys %{$activity}) {
        my $currency = $activity->{$loginid}->{currency};

        # this is for optimization else we would need to call in_USD for each record
        # this only calls if currency is not in hash
        $conversion_hash{$currency} = in_USD(1, $currency) unless exists $conversion_hash{$currency};

        my $csv = Text::CSV->new;

        my $first_funded_date =
            $activity->{$loginid}->{'first_funded_date'} ? Date::Utility->new($activity->{$loginid}->{'first_funded_date'})->date_yyyymmdd : '';
        my @output_fields = ($when->date_yyyymmdd, $loginid);

        if ($currency =~ /^(JPY|USD)$/) {
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{pnl});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{deposits});
            push @output_fields, formatnumber('amount', $currency, $activity->{$loginid}->{turnover_runbets});
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
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_runbets});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_intradays});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{turnover_others});
            push @output_fields, $first_funded_date;
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * $activity->{$loginid}->{'withdrawals'});
            push @output_fields, formatnumber('amount', 'USD', $conversion_hash{$currency} * ($activity->{$loginid}->{'first_funded_amount'} // 0));
        }

        $csv->combine(@output_fields);
        push @output, $csv->string;
    }

    return @output;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

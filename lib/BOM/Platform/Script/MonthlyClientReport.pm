package BOM::Platform::Script::MonthlyClientReport;
use strict;
use warnings;

use File::Path qw(make_path);
use Text::CSV;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use Date::Utility;

my $PREFIX_OUTPUT_PATH = '/db/f_broker';

sub go {
    my %params = @_;

    my $crdr   = $params{crdr}   || die;
    my $broker = $params{broker} || die;

    my $yyyymm = $params{yyyymm} || die;

    # The start date is the first day of that month
    my $start_date = Date::Utility->new("${yyyymm}-01");

    my $csv_dir  = $PREFIX_OUTPUT_PATH . "/$broker/monthly_client_report";
    my $csv_name = $csv_dir . "/${yyyymm}_${crdr}.csv";

    make_path($csv_dir);

    my $sql = "SELECT t.* from reporting.get_monthly_client_report(?, ?, ?) t";

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        })->db->dbic;

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            my @bind_params = ($crdr, $broker, $start_date->date_yyyymmdd);
            $sth->execute(@bind_params);
            my @headers = qw/Date Loginid Description CrDr_Amount Amount Currency Broker Type/;
            my $csv = Text::CSV->new({eol => "\n"});
            my $fh;
            while (my $row = $sth->fetchrow_arrayref) {
                unless ($fh) {
                    $fh = IO::File->new($csv_name, 'w') || die "writing $csv_name: $!";
                    $csv->print($fh, \@headers);
                }
                $csv->print($fh, $row);
            }
            $fh->close if $fh;
            return $sth->rows;
        });
}

sub run {
    my %params = @_;
    STDOUT->autoflush(1);    # flushes stdout progress report faster

    my $date = $params{date} || do {
        my $now = Date::Utility->new->minus_time_interval('1mo');
        sprintf '%s-%02s', $now->year, $now->month;
    };

    printf "Generating reports for date: %s...\n", $date;
    for my $broker (@{$params{brokers} // [qw/ MLT MX MF CR /]}) {
        for my $crdr (@{$params{report} // [qw/ debit credit /]}) {
            printf "%5s / %6s: %s.. ", $broker, $crdr, scalar(localtime);
            my $rows = go
                broker => $broker,
                crdr   => $crdr,
                yyyymm => $date;
            printf "%7d records\n", $rows;

        }
    }

    printf "%s: done\n", scalar(localtime);
    return;
}

1;

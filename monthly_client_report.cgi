#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Text::CSV;
use HTML::Entities;

use BOM::Backoffice::PlackHelpers qw( PrintContentType_excel );

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my %params = %{request()->params};

my $yyyymm = $params{yyyymm};
my $crdr   = $params{crdr};
my $broker = $params{broker};

my $dir       = "/db/f_broker/$broker/monthly_client_report";
my $csv_name  = "${yyyymm}_${crdr}.csv";
my $file_name = "$dir/$csv_name";

if (open my $fh, "<", $file_name) {
    PrintContentType_excel("${broker}_$csv_name", -s $file_name);
    local $/;
    print <$fh>;
    close $fh;

} else {
    PrintContentType();
    BrokerPresentation("MONTHLY CLIENT REPORT");
    Bar("MONTHLY CLIENT REPORT");
    print "<p>Sorry.. Monthly Client Report for " . encode_entities("$broker, $crdr, $yyyymm") . " is not available</p>";
    code_exit_BO();
}


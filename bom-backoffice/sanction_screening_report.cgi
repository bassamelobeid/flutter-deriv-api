#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Text::CSV;
use BOM::Backoffice::Sysinit ();

use BOM::Backoffice::CustomSanctionScreening;
use BOM::Config::Redis;
use JSON::MaybeUTF8               qw(:v1);
use BOM::Backoffice::PlackHelpers qw( PrintContentType_excel PrintContentType);
use constant FILE_NAME => "sanction_screening_report.csv";

BOM::Backoffice::Sysinit::init();

my $sanction_data = BOM::Backoffice::CustomSanctionScreening::retrieve_custom_sanction_data_from_redis();

my $data = $sanction_data->{data};

if ($data) {
    PrintContentType_excel(FILE_NAME);
    my $first_record = $data->[0];
    my @headers      = keys %$first_record;

    my $csv = Text::CSV->new({eol => "\n"});
    $csv->print(\*STDOUT, \@headers);
    foreach my $row (@$data) {
        my @values = map { $row->{$_} } @headers;
        $csv->print(\*STDOUT, \@values);
    }
} else {
    PrintContentType();
    code_exit_BO("No custom client list uploaded!!!");
}


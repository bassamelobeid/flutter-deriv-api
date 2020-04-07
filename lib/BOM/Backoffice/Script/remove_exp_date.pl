#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Database::ClientDB;
use Getopt::Long;
use Log::Any qw($log);
use Data::Dumper;
use Syntax::Keyword::Try;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s'    => \my $log_level,
    'o|output=s' => \my $file_dest,
    'd|dryrun'   => \my $dry_run_flag,
) or die;

$log_level    ||= 'info';
$dry_run_flag ||= 0;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

$log->infof("Start removing expiration date for POAs with setings: %s , %s \n", $log_level, $dry_run_flag);

sub get_target_doc_info {

    my $broker_code = shift;

    $log->infof("----- Fetching docs info from BROKER CODE: $broker_code -----");

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker_code,
        })->db->dbic;

    my $doc_details;

    try {
        $doc_details = $dbic->run(
            fixup => sub {
                $_->selectall_hashref(
                    "SELECT id, document_type, expiration_date, file_name from betonmarkets.client_authentication_document WHERE document_type IN ('proofaddress', 'payslip', 'bankstatement', 'cardstatement') AND expiration_date IS NOT NULL ",
                    "id"
                );
            });
    }
    catch {
        my $e = $@;
        die "Fail to retrieve document info: $e";
    };

    if ($doc_details) {
        my $filename = $file_dest // 'targeted_rows.txt';

        $log->infof("Start writting targeted to file: $filename");

        open(my $fh, '>>', $filename) or die "Could not open file '$filename' $!";

        for my $each_doc (keys $doc_details->%*) {
            my $doc = $doc_details->{$each_doc};
            $log->infof('ID: %s  ||  File Name: %s  || Doc_type: %s  ||  Exp_date: %s',
                $doc->{id}, $doc->{file_name}, $doc->{document_type}, $doc->{expiration_date});
            print $fh $broker_code . ", " . $doc->{id} . ", " . $doc->{document_type} . ", " . $doc->{expiration_date} . "\n";
        }
        close $fh;

        $log->infof("Writting targeted rows to file completed.");
    }

    my $num_of_rows = scalar keys $doc_details->%*;

    $log->infof("----- $num_of_rows CASES RETRIEVED FOR BROKER CODE: $broker_code -----\n");
    return;
}

sub update_target_doc_info {

    my $broker_code = shift;

    $log->infof("Start poa expiration_date removal for BROKER CODE: $broker_code");

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker_code,
        })->db->dbic;

    my $affected_rows;

    try {
        $affected_rows = $dbic->run(
            fixup => sub {
                $_->selectall_hashref(
                    "UPDATE betonmarkets.client_authentication_document SET expiration_date = NULL WHERE document_type IN ('proofaddress', 'payslip', 'bankstatement', 'cardstatement') AND expiration_date IS NOT NULL RETURNING id, document_type, expiration_date",
                    "id"
                );
            });
    }
    catch {
        my $e = $@;
        die "Failed to update doc info: $e";
    };

    if ($affected_rows) {
        my $filename = $file_dest // 'affected_rows.txt';

        $log->infof("Start writting affected rows to file: $filename");

        open(my $fh, '>>', $filename) or die "Could not open file '$filename' $!";

        for my $each_row (keys %$affected_rows) {
            my $row = $affected_rows->{$each_row};
            print $fh $broker_code . ", " . $row->{id} . ", " . $row->{document_type} . "\n";

        }
        close $fh;
    }

    $log->infof("Writting affected rows to file completed.");

    $log->infof(scalar(keys %$affected_rows) . " CASES UPDATED");

    $log->infof("Removal completed for BROKER CODE: $broker_code \n");

    return;
}

my @broker_codes = qw(CR MX MF MLT);

$dry_run_flag ? map { get_target_doc_info($_) } @broker_codes : map { update_target_doc_info($_) } @broker_codes;

$log->infof('Removal of expiration_date for POAs completed successfully');

1;

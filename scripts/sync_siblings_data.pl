#!/usr/bin/env perl

=head1 NAME

sync_siblings_data.pl

=head1 SYNOPSIS
 
perl sync_siblings_data.pl -file <CSV_file> -field <Field to copy> -field <Another field to copy>

Where <Field to populate> is the field that have to be copied from MF client account to CR.

eg:
perl sync_siblings_data.pl -f <CSV_file> -field account_opening_reason -field tax_identification_number -field tax_residence
where 'account_opening_reason', 'tax_identification_number', and 'tax_residence' are the fields that will be copied from the MF account of the client to given CR accounts.

#By default the fields will be 'account_opening_reason', 'tax_identification_number', and 'tax_residence'
perl sync_siblings_data.pl -f <CSV_file>

#for Dry Run
perl sync_siblings_data.pl -f <CSV_file> -dr 1
This will just print the details of 5 clients with the fields from both MF and CR accounts

#To adjust log level to show info logs aswell do (Default log level is warning):
perl sync_siblings_data.pl -f <CSV_file> -l info

# expected CSV format
binary_user_id  mf_login_ids    mf_tax_country  cr_tax_country  cr_login_ids
6282093         MF63849         South Africa    Zimbabwe        CR3038216,CR2693588,CR4070601,CR4204637

# Result CSV format containing the report of the sync
mf_login_id     cr_login_id     updated_field               old_value       new_value           error
MF000001        CR000001        tax_identification_number   111-111-111     222-222-222    
MF000001        CR000002        account_opening_reason      Speculative     Income Earning    
MF000004        CR000001                                                                        Invalid loginid: CR000001

The CSV will be exported to /tmp with the name of sync_output_<timestamp>.csv

=head1 OPTIONS

The following options are mandatory:

=over 4

=item B<-file, --CSV_file_path>

The path to the CSV file containing the binary_user_id, source mf_login_ids and target cr_login_ids.

=back

The following options are optional:

=over 4

=item B<-field, --field_to_copy>

The -field or --field_to_copy option specifies the fields that has to be copied from MF account to CR accounts. Valid values are 'account_opening_reason', 'tax_identification_number', and 'tax_residence'.

=item B<-dr, --dry_run>

If set to 1, the script will perform a dry run and print the details of 5 clients with the fields from both MF and CR accounts

=item B<-l, --log_level>

The log level to use for logging. Valid values are 'debug', 'info', 'warning', 'error', and 'fatal'. The default log level is 'warning'.

=back

=cut

package main;
use strict;
use warnings;

use Getopt::Long;
use Pod::Usage   qw(pod2usage);
use Text::CSV_XS qw( csv );
use Syntax::Keyword::Try;
use Time::Piece;
use Log::Any::Adapter qw(Stderr), log_level => 'warning';

use BOM::User::Client;
use BOM::User::Script::SiblingDataSync;

my @fields = qw(account_opening_reason tax_identification_number tax_residence);
GetOptions(
    "f|CSV_file_path=s" => \my $CSV_file_path,
    "dr|dry_run=i"      => \my $dry_run,
    "c|field=s@"        => \@fields,
    "l|log_level=s"     => sub { Log::Any::Adapter->set('Stderr', log_level => $_[1]) });

# Basic requirement for the script to work
pod2usage(1) unless ($CSV_file_path);

BOM::User::Script::SiblingDataSync->run({
    file_path  => $CSV_file_path,
    dry_run    => $dry_run,
    fields_ref => \@fields,
});

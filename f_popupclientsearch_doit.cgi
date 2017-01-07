#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use Try::Tiny;

use f_brokerincludeall;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

BOM::Backoffice::Auth0::can_access(['CS']);

my $broker       = request()->param('broker');
my $partialfname = request()->param('partialfname');
my $partiallname = request()->param('partiallname');
my $partialemail = request()->param('partialemail');
$partialfname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partiallname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partialemail =~ s/[\/\\\"\$]//g;    #strip unwelcome characters

$partialfname = '' if ($partialfname eq 'Partial FName');
$partiallname = '' if ($partiallname eq 'Partial LName');
$partialemail = '' if ($partialemail eq 'Partial email');

printf "<head><title>Searching for name [%s %s] or email [%s] in clients of %s</title></head><body>",
    map { encode_entities($_) } ($partialfname, $partiallname, $partialemail, $broker);

my %fields = (
    'first_name' => $partialfname,
    'last_name'  => $partiallname,
    'email'      => $partialemail,
);
my %non_empty_fields = (map { ($_, $fields{$_}) } (grep { $fields{$_} } (keys %fields)));
my $results;
if (%non_empty_fields) {
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    $results = $report_mapper->get_clients_result_by_field({
        'broker'        => $broker,
        'field_arg_ref' => \%non_empty_fields,
    });
} else {
    print "Please enter client details";
    print "<P><center><A HREF='javascript:history.go(-1);'>Back</a>";
    code_exit_BO();
}

if (not scalar @{$results}) {
    print "No match";
    print "<P><center><A HREF='javascript:history.go(-1);'>Back</a>";
    code_exit_BO();
}

BOM::Backoffice::Request::template->process('backoffice/client_search_result.html.tt', {results => $results})
    || die BOM::Backoffice::Request::template->error(), "\n";

print "<P><center><A HREF='javascript:history.go(-1);'>Back</a>";

code_exit_BO();

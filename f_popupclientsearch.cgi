#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use Try::Tiny;

use f_brokerincludeall;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

BOM::Backoffice::Auth0::can_access(['CS']);

my $broker       = request()->param('broker')       // "";
my $partialfname = request()->param('partialfname') // "";
my $partiallname = request()->param('partiallname') // "";
my $partialemail = request()->param('partialemail') // "";
$partialfname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partiallname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partialemail =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$broker =~ s/[\/\\\"\$]//g;          #strip unwelcome characters

my %fields = (
    'first_name' => $partialfname,
    'last_name'  => $partiallname,
    'email'      => $partialemail,
);
my %non_empty_fields = (map { ($_, $fields{$_}) } (grep { $fields{$_} } (keys %fields)));
my $results;

use Data::Dumper;

if (%non_empty_fields) {
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    warn Dumper($report_mapper);
    $results = $report_mapper->get_clients_result_by_field({
        'broker'        => $broker,
        'field_arg_ref' => \%non_empty_fields,
    });
}

BOM::Backoffice::Request::template->process(
    'backoffice/client_search.html.tt',
    {
        results    => $results,
        first_name => $partialfname,
        last_name  => $partiallname,
        email      => $partialemail,
        broker     => $broker
    }) || die BOM::Backoffice::Request::template->error(), "\n";
print Dumper($results);
code_exit_BO();

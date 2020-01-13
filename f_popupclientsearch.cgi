#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $broker        = request()->param('broker')        // "";
my $partialfname  = request()->param('partialfname')  // "";
my $partiallname  = request()->param('partiallname')  // "";
my $partialemail  = request()->param('partialemail')  // "";
my $phone         = request()->param('phone')         // "";
my $date_of_birth = request()->param('date_of_birth') // "";
$partialfname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partiallname =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$partialemail =~ s/[\/\\\"\$]//g;    #strip unwelcome characters
$phone =~ s/[\/\\\"\$]//g;           #strip unwelcome characters
$broker =~ s/[\/\\\"\$]//g;          #strip unwelcome characters
$date_of_birth = '' unless ($date_of_birth =~ /^\d{4,4}\-\d{1,2}\-\d{1,2}$/);
my %fields = (
    first_name    => $partialfname,
    last_name     => $partiallname,
    email         => $partialemail,
    phone         => $phone,
    date_of_birth => $date_of_birth,
);
my $non_empty_fields = {map { ($_, $fields{$_}) } (grep { $fields{$_} } (keys %fields))};
my $results;

if (%$non_empty_fields) {
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    $non_empty_fields->{broker} = uc($broker);
    $results = $report_mapper->get_clients_result_by_field($non_empty_fields);
}

BOM::Backoffice::Request::template()->process(
    'backoffice/client_search.html.tt',
    {
        results => $results,
        params  => $non_empty_fields,
        broker  => $broker,
        url     => request()->url_for("backoffice/f_popupclientsearch.cgi"),
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();

#!/usr/bin/perl
package main;
use strict 'vars';
use Try::Tiny;

use f_brokerincludeall;
use BOM::Platform::Data::Persistence::DataMapper::CollectorReporting;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

if (    BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server')
    and BOM::Platform::Runtime->instance->app_config->system->on_production)
{
    print "NOT RELEVANT FOR MASTER LIVE SERVER";
    code_exit_BO();
}

BOM::Platform::Auth0::can_access(['CS']);

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

print "<head><title>Searching for name [$partialfname $partiallname] or email [$partialemail] in clients of $broker</title></head><body>";

my %fields = (
    'first_name' => $partialfname,
    'last_name'  => $partiallname,
    'email'      => $partialemail,
);
my %non_empty_fields = (map { ($_, $fields{$_}) } (grep { $fields{$_} } (keys %fields)));
my $results;
if (defined %non_empty_fields && keys %non_empty_fields) {
    my $report_mapper = BOM::Platform::Data::Persistence::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'read_collector'
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

BOM::Platform::Context::template->process('backoffice/client_search_result.html.tt', {results => $results})
    || die BOM::Platform::Context::template->error(), "\n";

print "<P><center><A HREF='javascript:history.go(-1);'>Back</a>";

code_exit_BO();

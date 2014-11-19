#!/usr/bin/perl
package main;

use strict;
use warnings;

use YAML::XS;
use XML::Simple;
use BOM::Platform::Plack qw( PrintContentType PrintContentType_XML );

use f_brokerincludeall;

$YAML::XS::QuoteNumericStrings = 0;

system_initialize();

BOM::Platform::Auth0::can_access(['CS']);

my $loginID       = request()->param('loginID');
my $search_option = request()->param('search_option');

my $client = BOM::Platform::Client->new({loginid => $loginID}) || die "could not get client for $loginID";

my $report = BOM::Platform::ProveID->new(
    client        => $client,
    search_option => $search_option
  )->get_192_xml_report()
  || die "no 192 $search_option report available for $client";

if (request()->param('raw')) {
    PrintContentType_XML();
    print $report;
} else {
    PrintContentType();
    my $yamlized = Dump(XMLin($report));
    print qq~
    <!doctype html>
    <html>
     <head>
        <link  href="[% request.url_for('css/external/shThemeDefault.css', undef, undef, {internal_static => 1}) %]" rel="stylesheet" type="text/css" />
      ~;
    BOM::Platform::Context::template->process('backoffice/global/javascripts.html.tt',
        {javascript => BOM::View::JavascriptConfig->instance->config_for()})
      || die BOM::Platform::Context::template->error;
    foreach my $js_file (BOM::View::JavascriptConfig->instance->bo_js_files_for($0)) {
        print '<script type="text/javascript" src="' . $js_file . '"></script>';
    }
    print qq~
      </head>
       <body>
      ~;
    BOM::Platform::Context::template->process('backoffice/view-192-response-yaml.html.tt', {yamlized => $yamlized});
    print qq~
       </body>
      </html>
      ~;
}

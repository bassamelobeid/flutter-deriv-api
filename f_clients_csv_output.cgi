#!/usr/bin/perl
package main;
use strict 'vars';

use CGI;
use f_brokerincludeall;
use subs::subs_client_trades_details;
use BOM::Platform::Plack qw( PrintContentType PrintContentType_excel);
use BOM::Platform::Sysinit ();
use Text::CSV;
BOM::Platform::Sysinit::init();

PrintContentType();

my $cgi = CGI->new;


my $broker    = $cgi->param('broker');
my $loginid   = $cgi->param('loginid');
my $startdate = $cgi->param('startdate');
my $enddate   = $cgi->param('enddate');
my $csvfile  = "${loginid}_${startdate}_${enddate}";

eval{

   PrintContentType_excel("$csvfile.csv");
   my $csv  = Text::CSV->new({
           binary        => 1,
           eol           => "\n"
  });

   my ($headers, @rows) = get_trades_details({
           broker      => $broker,
           loginid     => $loginid,
           startdate   => $startdate,
           enddate     => $enddate,
   });

   die "no data found\n" unless @rows;

   my @headers = sort keys %$headers;
   $csv->combine(@headers);
   print $csv->string;

   foreach my $row (@rows) {
       my @row = map { $row->{$_} // '' } @headers;
      $csv->combine(@row);
      print $csv->string;
   }


};

if (my $err = $@) {
            PrintContentType();
            BrokerPresentation("Client Trades CSV for $csvfile");
            print qq[<div class="ui-widget ui-widget-content ui-state-error">Error: $err</div>];
            code_exit_BO();
}

1;


#!/usr/bin/perl
package main;
use strict;
use warnings;

use File::Find::Rule;
use File::Slurp;

use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::ProveID;
use BOM::Platform::Runtime;
use BOM::Platform::Client;

BOM::Utility::Log4perl::init_log4perl_console;

my $logger       = get_logger();
my $accounts_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_accounts";

$logger->debug("Starting..");
for my $broker (BOM::Platform::Runtime->instance->broker_codes->all_codes) {
    next unless $broker =~ /^(CR|MX|MLT)$/;
    my $dir = "$accounts_dir/$broker/192com_authentication";
    $logger->debug("Looking in $dir for ProveID XML reports without corresponding PDF files for $broker");
    my $xml_dir = "$dir/xml";
    my $pdf_dir = "$dir/pdf";
    File::Find::Rule->new->file->exec(sub { -M $_ < 360 })->exec(sub { !-e "$pdf_dir/$_.pdf" })->exec(
        sub {
            my ($loginid, $search_option) = $_ =~ /^([^.]+)[.]([^.]+)$/;
            my $result_as_xml = read_file($_);
            my $client = eval { BOM::Platform::Client->new({loginid => $loginid}) } || do {
                my $err = $@;
                $logger->error("Can't identify client $loginid: $err");
                return;
            };

            $logger->debug("Getting $search_option pdf-result for $client");
            BOM::Platform::ProveID->new(
                client        => $client,
                result_as_xml => $result_as_xml,
                search_option => $search_option
              )->save_pdf_result

              ? $logger->debug("Saved $search_option result for $client")
              : $logger->warn("Failed to save $search_option result for $client");

        })->in($xml_dir);
}
$logger->debug("Done.");

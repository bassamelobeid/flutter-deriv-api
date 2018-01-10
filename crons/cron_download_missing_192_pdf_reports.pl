#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use File::Find::Rule;
use Path::Tiny;

use BOM::Platform::ProveID;
use BOM::Platform::Runtime;
use Client::Account;
use LandingCompany;

my $accounts_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_accounts";

for my $broker (LandingCompany::Registry::all_broker_codes) {
    next unless $broker =~ /^(CR|MX|MLT)$/;
    my $dir     = "$accounts_dir/$broker/192com_authentication";
    my $xml_dir = "$dir/xml";
    my $pdf_dir = "$dir/pdf";
    File::Find::Rule->new->file->exec(sub { -M $_ < 30 })->exec(sub { !-e "$pdf_dir/$_.pdf" })->exec(
        sub {
            my ($loginid, $search_option) = $_ =~ /^([^.]+)[.]([^.]+)$/;
            my $result_as_xml = path($_)->slurp_utf8;
            my $client = eval { Client::Account->new({loginid => $loginid, db_operation => 'replica'}) } || do {
                my $err = $@;
                warn("Error: can't identify client $loginid: $err");
                return;
            };

            BOM::Platform::ProveID->new(
                client        => $client,
                result_as_xml => $result_as_xml,
                search_option => $search_option
                )->save_pdf_result
                || warn("Failed to save $search_option result for $client");

        })->in($xml_dir);
}

#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use JSON qw(to_json);
use Carp;
use File::Slurp;
use Try::Tiny;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType PrintContentType_JavaScript );
use BOM::MarketData::Parser::Bloomberg::RequestFiles;
use BOM::MarketData::Parser::Bloomberg::FileDownloader;

system_initialize();

PrintContentType();

my $cgi               = CGI->new;
my $volatility_source = $cgi->param('master_request_file');
my $request_file      = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(volatility_source => $volatility_source);

# regenerates request files
eval { $request_file->generate_request_files('daily') };

my @table_rows;
foreach my $filename (@{$request_file->master_request_files}) {

    $filename = 'd_' . $filename;
    my $file  = BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif . '/' . $filename;
    my @lines = read_file($file);

    my ($flag, $time);
    foreach my $line (@lines) {
        $flag = $1 if $line =~ /PROGRAMFLAG=(\w+)/;
        $time = $1 if $line =~ /TIME=(\w+)/;
    }

    my $args = {
        filename  => $filename,
        file_url  => request()->url_for('temp/' . $filename)->to_string,
        frequency => $flag,
        time      => $time
    };
    push @table_rows, $args;
}

my $response = try {
    {
        success => 1,
        rows    => to_json(\@table_rows),
    };
}
catch {
    {
        success => 0,
        reason  => $_,
    };
};

PrintContentType_JavaScript();
print to_json($response);
code_exit_BO();

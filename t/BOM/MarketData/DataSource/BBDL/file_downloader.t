#!/usr/bin/perl

use strict;
use warnings;
use Test::Exception;
use Test::MockObject::Extends;
use Test::Log4perl;
use Test::More tests => 3;
use Test::NoWarnings;

use Path::Tiny;
use BOM::MarketData::Parser::Bloomberg::FileDownloader;
use Date::Utility;
use BOM::Utility::Log4perl;

subtest 'sftp_server_ip(s).' => sub {
    plan tests => 2;

    my $bbdl = BOM::MarketData::Parser::Bloomberg::FileDownloader->new(data_dir => '/tmp');

    is(ref $bbdl->sftp_server_ips, 'ARRAY', 'sftp_server_ips type.');

    like($bbdl->sftp_server_ip, qr/^\d+\.\d+\.\d+\.\d+$/, 'sftp_server_ip looks like an IP address.');
};

my $dirname         = path(__FILE__)->parent;
my $sample_csv_file = $dirname->child("sample_OVDV_vols.csv.enc");
my $now             = Date::Utility->new;

subtest 'Grabbing files.' => sub {
    plan tests => 1;

    my $bbdl = BOM::MarketData::Parser::Bloomberg::FileDownloader->new(data_dir => "/tmp");

    throws_ok { $bbdl->grab_files({file_type => 'junk'}) } qr/Invalid file_type \[junk\] passed/,
        'Passing an invalid file_type to grab_files results in a die.';
};

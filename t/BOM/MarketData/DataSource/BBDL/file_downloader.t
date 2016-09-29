#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::Exception;
use Test::MockObject::Extends;
use Test::More tests => 1;

use Path::Tiny;
use Bloomberg::FileDownloader;
use Date::Utility;


my $dirname         = path(__FILE__)->parent;
my $sample_csv_file = $dirname->child("sample_OVDV_vols.csv.enc");
my $now             = Date::Utility->new;

subtest 'Grabbing files.' => sub {
    plan tests => 1;

    my $bbdl = Bloomberg::FileDownloader->new(data_dir => "/tmp");

    throws_ok { $bbdl->grab_files({file_type => 'junk'}) } qr/Invalid file_type \[junk\] passed/,
        'Passing an invalid file_type to grab_files results in a die.';
};

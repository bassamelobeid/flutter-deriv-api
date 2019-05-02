#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Chronicle;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use YAML qw(LoadFile);
STDOUT->autoflush(1);

# Information
# For normalize index generaion, we need a set of calibration parameters.
# There is a docker on quants.regentmarkets.com to run the quants's R script to calibrate the parameters and put on S3 server. (On last Saturday of every month)
# This script will then download the calibration parameters yaml file from S3 and update the redis and chronicle accordingly for the generation. (On first Saturday of every month)


my $download_redis = 0;
my $upload_redis   = 0;
my $s3_config      = '/etc/rmg/normalized_idx_replicator.yml';
my $file_name      = 'output.yml';
my $help;

my $config = LoadFile($s3_config);

my $loop = IO::Async::Loop->new;
my $s3   = Net::Async::Webservice::S3->new(
    access_key => $config->{aws_access_key_id},
    secret_key => $config->{aws_secret_access_key},
    bucket     => $config->{aws_bucket},
);
$loop->add($s3);

my $namespace = 'NORMALIZED_INDEX_COEF';
my $content   = $s3->get_object(key => $file_name)->get;
# The content will be as follow:
#    frxEURUSD => {
#        start   => '2018-09-25',
#        end     => '2019-03-26',
#        mu_x    => -4.4761848e-09,
#        sigma_x => 1.6976427e-05,
#        delta_l => 0.343821,
#        delta_r => 0.346219,
#        gamma   => 0.0,
#        alpha_l => 1.0,
#        alpha_r => 1.0
#    },
my $writer    = BOM::Config::Chronicle::get_chronicle_writer();
my $timestamp = Date::Utility->new;
my @lines     = split /\n/, $content;
for (my $i = 0; $i < scalar(@lines); $i += 10) {
    my $symbol = $lines[$i];
    $symbol =~ s/://g;
    my %data;
    for (my $j = 1; $j <= 9; $j++) {
        my $line = $lines[$i + $j];
        $line =~ s/ //g;
        $line =~ s/'//g;
        my ($field, $data) = split(/:/, $line);
        $data{$field} = $data;
    }
    $writer->set($namespace, $symbol, \%data, Date::Utility->new);
}


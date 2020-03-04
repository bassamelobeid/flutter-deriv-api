#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Redis;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);
use IO::Async::Loop;
use JSON;
use Net::Async::Webservice::S3;
use Path::Tiny;
use Syntax::Keyword::Try;
use YAML qw(LoadFile);

STDOUT->autoflush(1);

# defaults
my $download_redis = 0;
my $upload_redis   = 0;
my $s3_config      = '/etc/rmg/redis_s3.yml';
my $file_name      = 'binary_chronicle_redis_exchangerates.dump';
my $help;

GetOptions(
    'c|s3-config=s'      => \$s3_config,
    'd|download-redis=i' => \$download_redis,
    'u|upload-redis=i'   => \$upload_redis,
    'f|dump-file=s'      => \$file_name,
    'h|help'             => \$help,
);

my $show_help = $help || !($download_redis || $upload_redis);
die <<"EOF" if ($show_help);
usage: $0
This script is used to do two things:
- extract replicated redis data and upload it to S3
- download from S3 and import it to redis along with database.

All Redis keys will be imported.

These options are available:
  -c, --s3-config          The path to yaml config file with AWS keys (default: '/etc/rmg/redis_s3.yml').
  -d, --download-redis     Set it when you want redis data to be downloaded and imported.
  -u, --upload-redis       Set it when you want redis data to be extracted and uploaded to redis
  -f, --dump-file          Name of dump file (default: binary_chronicle_redis.dump)
  -h, --help               Show this message.
EOF

my $config = LoadFile($s3_config);

my $loop = IO::Async::Loop->new;
my $s3   = Net::Async::Webservice::S3->new(
    access_key => $config->{aws_access_key_id},
    secret_key => $config->{aws_secret_access_key},
    bucket     => $config->{aws_bucket},
);
$loop->add($s3);

sub upload_redis {

    my $r       = BOM::Config::Redis::redis_exchangerates();
    my $keys    = $r->keys('*');
    my %data    = map { $_ => {$r->hgetall($_)->@*} } $keys->@*;
    my $content = encode_json(\%data);
    
    try {
        $s3->put_object(
            key   => $file_name,
            value => $content
        )->get;
    }
    catch {
        die "Failed to upload redis dump data to S3. Error is $@.";
    }
}

sub download_redis {
    my $data      = decode_json($s3->get_object(key => $file_name)->get);
    my $writer    = BOM::Config::Redis::redis_exchangerates_write();

    foreach my $record_key (keys %$data) {
    
        my $content = $data->{$record_key};
        my @details;
        
        push @details, $_, $content->{$_} for keys %$content;
    
        $writer->hmset($record_key, @details);
    }
    print "Updated redis_exchangerates successful\n";
}

if ($upload_redis) {upload_redis};
if ($download_redis) {download_redis};

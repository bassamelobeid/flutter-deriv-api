#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Redis;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);
use IO::Async::Loop;
use JSON::MaybeXS;
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
    ssl        => 1,
);
$loop->add($s3);

sub _get_content {

    my ($r, $keys) = @_;
    my $content;
    my %data;

    for my $key ($keys->@*) {

        if ($r->type($key) eq 'hash') {
            $data{$key} = $r->hgetall($key);
        } elsif ($r->type($key) eq 'string') {
            $data{$key} = $r->get($key);
        } elsif ($r->type($key) eq 'list') {
            $data{$key} = $r->lrange($key, 0, -1);
        } elsif ($r->type($key) eq 'set') {
            $data{$key} = $r->smembers($key);
        } elsif ($r->type($key) eq 'zset') {
            $data{$key} = $r->zrange($key, 0, -1, 'WITHSCORES');
        }

    }

    $content = encode_json(\%data);

    return $content;

}

sub upload_redis {

    my $r       = BOM::Config::Redis::redis_exchangerates();
    my $keys    = $r->keys('*');
    my $content = _get_content($r, $keys);
    try {
        $s3->put_object(
            key   => $file_name,
            value => $content
        )->get;
    } catch ($e) {
        die "Failed to upload redis dump data to S3. Error is $e.";
    }
}

sub download_redis {
    my $data   = decode_json($s3->get_object(key => $file_name)->get);
    my $writer = BOM::Config::Redis::redis_exchangerates_write();

    foreach my $record_key (keys %$data) {

        my $content = $data->{$record_key};
        my @details;

        if (ref $content eq "ARRAY") {
            if ($record_key =~ /^exchange_rates(_::queue)?/) {
                # if it is the queue rate we need to store it as zset
                if ($1) {
                    my @content_array = @$content;
                    # the zset is stored like an array so we have [rate, index, rate, index ...]
                    # is that why we set the loop to be incremented by two
                    for (my $i = 0; $i <= $#content_array; $i += 2) {
                        # the index position is after the rate
                        my $set_index = $i + 1;
                        $writer->zadd($record_key, $content_array[$set_index], $content_array[$i]);
                    }
                    next;
                }

                $writer->hmset($record_key, $content->@*);
            }
        }

        unless (ref $content) {

            if ($writer->type($record_key) eq 'string') {
                $writer->set($record_key, $content);
            }

        }

    }
    print "Updated redis_exchangerates successful\n";
}

if ($upload_redis)   { upload_redis }
if ($download_redis) { download_redis }

#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Redis;
use BOM::Config::Chronicle;
use Date::Utility;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);
use IO::Async::Loop;
use JSON::MaybeXS;
use Net::Async::Webservice::S3;
use Path::Tiny;
use Syntax::Keyword::Try;
use YAML qw(LoadFile);

STDOUT->autoflush(1);

# defaults
my $download_redis      = 0;
my $upload_redis        = 0;
my $s3_config           = '/etc/rmg/redis_s3.yml';
my $file_name           = 'binary_chronicle_redis.dump';
my $flush_before_import = 0;
my $help;

GetOptions(
    'c|s3-config=s'      => \$s3_config,
    'd|download-redis=i' => \$download_redis,
    'u|upload-redis=i'   => \$upload_redis,
    'f|dump-file=s'      => \$file_name,
    'h|help'             => \$help,
    'fa|fulsh-all=i'     => \$flush_before_import,
);

my $show_help = $help || !($download_redis || $upload_redis);
die <<"EOF" if ($show_help);
usage: $0
This script is used to do two things:
- extract replicated redis data and upload it to S3
- download from S3 and import it to redis along with database.

Redis keys that will be imported:
'interest*', 'dividend*', 'economic*', 'volatility*', 'correlation*', 'partial_trading*', 'holidays*', 'app_settings*', 'cryptocashier_settings*, quants_config*'

These options are available:
  -c, --s3-config          The path to yaml config file with AWS keys (default: '/etc/rmg/redis_s3.yml').
  -d, --download-redis     Set it when you want redis data to downloaded and imported.
  -u, --upload-redis       Set it when you want redis data to be extracted and uploaded to redis
  -f, --dump-file          Name of dump file (default: binary_chronicle_redis.dump)
  -h, --help               Show this message.
  -fa, --fulsh-all         Flush all the data redis data before imported.
EOF

my @redis_keys = (
    'interest', 'dividend',     'economic', 'volatility', 'correlation', 'partial_trading',
    'holidays', 'app_settings', 'cryptocashier_settings', 'quants_config'
);
my $config = LoadFile($s3_config);

my $loop = IO::Async::Loop->new;
my $s3   = Net::Async::Webservice::S3->new(
    access_key => $config->{aws_access_key_id},
    secret_key => $config->{aws_secret_access_key},
    bucket     => $config->{aws_bucket},
);
$loop->add($s3);

sub upload_redis {

    my $r       = BOM::Config::Redis::redis_replicated_read();
    my @keys    = map { @{$r->scan_all(MATCH => "$_*")} } @redis_keys;
    my %data    = map { $_ => $r->get($_) } grep { $r->type($_) eq 'string' } @keys;
    my $content = join "\n" => map { "$_ $data{$_}" } keys %data;

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
    my $content   = $s3->get_object(key => $file_name)->get;
    my $writer    = BOM::Config::Chronicle::get_chronicle_writer();
    my $timestamp = Date::Utility->new;

    if ($flush_before_import) {
        # Remove chronicle keys related to app_settings, cryptocashier_settings and quants_config
        my @keys = map { @{$writer->cache_writer->scan_all(MATCH => "$_*")} } ('app_settings', 'cryptocashier_settings', 'quants_config');
        map { $writer->cache_writer->del($_) } @keys;
    }

    my @lines = split /\n/, $content;
    foreach my $line (@lines) {
        chomp $line;

        my @parts = split / /, $line, 2;

        my $doc_key = $parts[0];
        my $doc     = $parts[1];
        $doc = JSON->new->allow_nonref->decode($doc);

        @parts = split /::/, $doc_key;

        my $category = $parts[0];
        my $key      = $parts[1];
        # we have $doc_key like economic_events_cache_snapshot that doesn't follow the naming convention.
        # skip this for now.
        next unless $key;

        $writer->set($category, $key, $doc, $timestamp);
        print "updated $category :: $key\n";
    }

}

upload_redis   if $upload_redis;
download_redis if $download_redis;


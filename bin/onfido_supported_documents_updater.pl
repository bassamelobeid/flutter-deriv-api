#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Onfido;
use Getopt::Long qw(GetOptions);
use YAML::XS     qw(DumpFile);

# If the dump option is given will dump the new configuration into the YML file.

my $dump;

# the clear option clears the cache

my $clear;

# print out the current version and json

my $verbose;

GetOptions(
    'd|dump=i'    => \$dump,
    'c|clear=i'   => \$clear,
    'v|verbose=i' => \$verbose,
);

if ($clear) {
    BOM::Config::Onfido::clear_supported_documents_cache();
}

BOM::Config::Onfido::supported_documents_updater();

if ($dump) {
    # This dump let you check the diff
    # and provide a sane initial file version
    my $details = BOM::Config::Onfido::_get_country_details();

    # give ordered data back to the file
    my $data = [map { $details->{$_} } sort keys $details->%*];

    DumpFile('/home/git/regentmarkets/perl-Business-Config/share/config/onfido_supported_documents.yml', $data);
}

if ($verbose) {
    my $redis   = BOM::Config::Redis::redis_replicated_read();
    my $version = $redis->get(BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY) // '';
    my $json    = $redis->get(BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY)      // '';

    print "Version = $version\n";
    print "$json\n";
}

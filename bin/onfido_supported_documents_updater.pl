#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::Config::Onfido;
use Getopt::Long qw(GetOptions);
use YAML::XS     qw(DumpFile);

# If the dump option is given will dump the new configuration into the YML file.

my $dump;

GetOptions(
    'd|dump=i' => \$dump,
);

BOM::Config::Onfido::supported_documents_updater();

if ($dump) {
    # This dump let you check the diff
    # and provide a sane initial file version
    my $details = BOM::Config::Onfido::_get_country_details();

    # give ordered data back to the file
    my $data = [map { $details->{$_} } sort keys $details->%*];

    DumpFile('/home/git/regentmarkets/bom-config/share/onfido_supported_documents.yml', $data);
}

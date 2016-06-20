package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

use Data::UUID;
use YAML::XS qw(LoadFile);
use BOM::System::Localhost;
use BOM::System::Config;

use constant quants => LoadFile('/home/git/regentmarkets/bom-platform/config/quants_config.yml');

sub get_static_path {
    return "/home/git/binary-com/binary-static/src/";
}

sub get_static_url {
    return "https://www.binary.com/";
}

sub get_customer_support_email {
    return 'support@binary.com';
}

sub get_allowed_broker_codes {
    return ['MX', 'MF', 'MLT', 'CR', 'JP', 'VRTC', 'VRTJ', 'FOG'];
}

sub read_config {
    my $flag = 0;
    my $static_hash;
    if (open my $fh, '<', '/etc/rmg/version') {    ## no critic (RequireBriefOpen)
        while (my $line = <$fh>) {
            chomp $line;
            if ($flag) {
                $line =~ s/commit://;
                $line =~ s/^\s+|\s+$//;
                $static_hash = $line;
                last;
            }
            if ($line =~ /environment-manifests(?:-www2|-qa)?$/) {
                $flag = 1;
            }
        }
        close $fh;
    }
    $static_hash = Data::UUID->new->create_str() unless $static_hash;
    return {
        binary_static_hash => $static_hash,
    };
}

{
    my $config = read_config;

    sub get_config {
        return $config;
    }
}

1;

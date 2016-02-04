package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

use Data::UUID;

sub get_display_languages {
    return ['EN', 'ID', 'RU', 'ES', 'FR', 'PT', 'DE', 'ZH_CN', 'PL', 'AR', 'ZH_TW', 'VI', 'IT'];
}

sub get_static_path {
    return "/home/git/binary-com/binary-static/";
}

sub get_static_url {
    if (BOM::System::Localhost::name() eq 'wwwpool00') {
        return "https://static-beta.binary.com/";
    }
    return "https://static.binary.com/";
}

sub get_customer_support_email {
    return 'support@binary.com';
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
            if ($line =~ /environment-manifests$/) {
                $flag = 1;
            }
        }
        close $fh;
    } else {
        $static_hash = Data::UUID->new->create_str();
    }
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

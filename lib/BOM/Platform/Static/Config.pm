package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

use Data::UUID;
use BOM::System::Localhost;
use BOM::System::Config;

sub get_display_languages {
    return ['EN', 'ID', 'RU', 'ES', 'FR', 'PT', 'DE', 'ZH_CN', 'PL', 'AR', 'ZH_TW', 'VI', 'IT'];
}

sub get_static_path {
    if (BOM::System::Config::node->{www2} eq 'true' or BOM::System::Config::env =~ /^qa\d+$/) {
        return "/home/git/binary-static/binary-static-www2/";
    }
    return "/home/git/binary-com/binary-static/";
}

sub get_static_url {
    if (BOM::System::Config::node->{www2} eq 'true') {
        return "https://static-www2.binary.com/";
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

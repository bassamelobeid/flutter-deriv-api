package BOM::MT5::BOUtility;

use strict;
use warnings;

use BOM::Config;
use List::MoreUtils qw(uniq);

sub valid_mt5_check {
    my $mt5_accounts = shift;

    my $config = BOM::Config::mt5_webapi_config();
    my @invalid_mt5;
    foreach my $mt5_id (@$mt5_accounts) {
        unless ($mt5_id =~ /^(MT|MTR|MTD)\d+$/) {
            push @invalid_mt5, "$mt5_id - Invalid Format <br>";
            next;
        }

        my $server_type;
        $server_type = 'real' if $mt5_id =~ /^(MT|MTR)\d+$/;
        $server_type = 'demo' if $mt5_id =~ /^MTD\d+$/;

        unless ($server_type eq 'real') {
            push @invalid_mt5, "$mt5_id - Demo Account not Allowed <br>";
            next;
        }

        my $valid_range;
        my ($login_id) = $mt5_id =~ /([0-9]+)/;
        for my $server_key (keys $config->{$server_type}->%*) {
            my @accounts_ranges = $config->{$server_type}->{$server_key}->{accounts}->@*;
            for (@accounts_ranges) {
                $valid_range = 1 if ($login_id >= $_->{from} and $login_id <= $_->{to});
            }
        }

        unless ($valid_range) {
            push @invalid_mt5, "$mt5_id - Unexpected login (not in range) <br>";
            next;
        }
    }

    return \@invalid_mt5;
}

1;

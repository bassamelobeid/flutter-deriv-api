#!/usr/bin/env perl

=head1 NAME

    remove_client_status

=head1 SYNOPSIS

    perl remove_client_status.pl -f <csv_file> -s <status>

=cut

use strict;
use warnings;

use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => 'info';
use Log::Any qw($log);
use Pod::Usage qw(pod2usage);
use Text::CSV;

use BOM::User::Client;

GetOptions(
    "f|csv_file_path=s" => \my $csv_file_path,
    "s|status=s"        => \my $status,
);

# Basic requirement for the script to work
pod2usage(1) unless ($csv_file_path && $status);

sub get_client_logins {
    my $file_path = shift;

    # Read/parse CSV
    my $csv = Text::CSV->new({
        binary    => 1,
        auto_diag => 1
    });

    open my $fh, "<:encoding(utf8)", $file_path or die $!;
    my $arrayref = $csv->getline_all($fh);
    close $fh;

    return () unless $arrayref && $arrayref->@*;
    return map { $_->[0] } $arrayref->@*;
}

sub remove_client_status {
    my ($file_path, $status_code) = @_;
    my @loginids = get_client_logins($file_path);
    $log->infof('Count of the clients: %s', scalar @loginids);
    return unless scalar @loginids;

    my $clear_method = 'clear_' . $status_code;
    for my $loginid (@loginids) {
        my $client = BOM::User::Client->new({loginid => $loginid});
        $client->status->$clear_method;
        $log->infof('Status removed for client: %s', $loginid);
    }
}

remove_client_status($csv_file_path, $status);

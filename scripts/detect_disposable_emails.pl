#!/usr/bin/perl

=head1 NAME

detect-disposable-emails

=head1 SYNOPSIS

perl detect-disposable-emails.pl [options]

 Options
  -d, --domains_file_path       File path to the list of domain names which this script will consider a disposable email (txt format: each domain on new line)
  -u, --users_data_file_path    File path to the list of users (csv format: header "id" and "email" must be included)
  -o, --output_file_path        File path to where to save the output file (default to the script directory)
  -h, --help                    Show this message.

=head1 DESCRIPTION

This script is to detect the users who are using a disposable emails    

=cut

use strict;
use warnings;

use Pod::Usage;
use Text::CSV;
use Getopt::Long;
use Email::Valid;

GetOptions(
    'd|domains_file_path:s'    => \my $domains_file_path,
    'u|users_data_file_path:s' => \my $users_data_file_path,
    'o|output_file_path=s'     => \(my $disposable_email_users_file_path = "./disposable_email_users.csv"),
    'h|help'                   => \my $help,
) or die("Use --help for details of use\n");

pod2usage({
        -verbose  => 99,
        -sections => "NAME|SYNOPSIS|DESCRIPTION|OPTIONS",
    }) if $help;

sub get_domains_list {
    my %hash;
    open my $fh_domains, '<', $domains_file_path or die $!;

    while (<$fh_domains>) {
        s/[\r\n]+$//;
        $hash{$_} = '1';
    }

    close($fh_domains);
    return \%hash;
}

sub domain_extraction {
    my $email = shift;

    return '' unless $email;

    my @domain = split(/\@/, $email);
    return lc($domain[1]);
}

sub disposable_email_users_list {
    my $domains_list = get_domains_list();

    # Read/parse CSV
    my $csv = Text::CSV->new({
        binary    => 1,
        eol       => $/,
        auto_diag => 1,
    });

    open my $fh_in_users,  "<:encoding(utf8)", $users_data_file_path             or die $!;
    open my $fh_out_users, ">:encoding(utf8)", $disposable_email_users_file_path or die $!;

    my $ra_colnames = $csv->getline($fh_in_users);
    $csv->column_names(@$ra_colnames);
    my $users_ref = $csv->getline_hr_all($fh_in_users);

    $csv->print($fh_out_users, $ra_colnames);

    for my $hash_ref (@$users_ref) {
        next unless Email::Valid->address($hash_ref->{email});

        my $domain_name = domain_extraction($hash_ref->{email});

        my @arr = ($hash_ref->{id}, $hash_ref->{email});
        $csv->print($fh_out_users, \@arr) if ($domains_list->{$domain_name});
    }

    close($fh_out_users);
    close($fh_in_users);

}

disposable_email_users_list();

1;

#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::PictureCollector;
use Getopt::Long;
use Future::AsyncAwait;

=head1 NAME

picture_collector.pl

=head1 SYNOPSIS

perl picture_collector.pl --country=br --document_type=passport --side=front --total=10 --status=verified --broker=CR --bundle=/tmp/kyc_bundle


=head1 DESCRIPTION

This script generates a bundle of KYC pictures.

For more details look at the L<BOM::User::Script::PictureCollector> package.

=cut

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
    'country=s'       => \my $country,
    'document_type=s' => \my $document_type,
    'total=i'         => \my $total,
    'broker=s'        => \my $broker,
    'status=s'        => \my $status,
    'bundle=s'        => \my $bundle,
    'dryrun=i'        => \my $dryrun,
    'side=s'          => \my $side,
    'page_size=i'     => \my $page_size,
) or die;

(
    async sub {
        await BOM::User::Script::PictureCollector->run({
            country       => $country,
            document_type => $document_type,
            total         => $total,
            broker        => $broker,
            status        => $status,
            bundle        => $bundle,
            dryrun        => $dryrun,
            side          => $side,
        });
    })->()->get;

package BOM::User::Script::PictureCollector;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::PictureCollector - KYC Picture collector

=head1 SYNOPSIS

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

=head1 DESCRIPTION

This module is used by the `picture_collector.pl` script. Meant to provide a testable
collection of subroutines.

Will generate a bundle of KYC pictures.

=cut

use Scalar::Util qw/looks_like_number/;
use Future::AsyncAwait;
use BOM::Database::ClientDB;
use BOM::Platform::S3Client;
use BOM::Config;
use HTTP::Tiny;
use File::Path qw(make_path);

=head2 run

Takes a hashref of parameters as:

=over

=item * C<country> - 2 letter country code 

=item * C<broker> - a broker code to get the pictures from

=item * C<total> - number of pictures to get

=item * C<document_type> - type of the document we are interested into (e.g: passport, drivers_license, etc)

=item * C<status> - status of the picture we are interested into (e.g: verified, rejected)

=item * C<side> - side of the document (optional if not given we won't query by document side, e.g: back, front)

=item * C<bundle> - a writable path within the filesystem (optional, defaults to `/tmp/kyc_bundle`)

=item * C<page_size> - how many items to get per DB hit (optional, default to 100)

=back

Returns a L<Future> which resoles to a C<hashref>.

The hashref maps to the bundle filesystem of all the downloaded pictures. e.g:

{
    "ar" => {
        "passport" => {
            "verified" => [
                "CR9000000.png"
                ...
            ]
        }
    }
}

=cut

async sub run {
    my ($self, $args) = @_;
    my $files = {};

    my ($country, $broker, $total, $document_type, $status, $bundle, $dryrun, $page_size) =
        @{$args}{qw/country broker total document_type status bundle dryrun page_size/};

    $bundle //= '/tmp/kyc_bundle';

    die 'country is mandatory'       unless $country;
    die 'broker is mandatory'        unless $broker;
    die 'total is mandatory'         unless $total;
    die 'total should be numeric'    unless looks_like_number($total);
    die 'document type is mandatory' unless $document_type;
    die 'status is mandatory'        unless $status;
    die 'bundle is not a directory'  unless -d $bundle;
    die 'bundle is not writable'     unless -w $bundle;

    $page_size //= 100;

    die 'page size should be numeric' unless looks_like_number($page_size);

    $total     = int($total);
    $page_size = int($page_size);

    $args->{total}     = $total;
    $args->{page_size} = $page_size;

    return undef if $dryrun;

    my $last_id = 0;
    my $curr_id;

    while ($total > 0) {
        my $curr_page_size = $total < $page_size ? $total : $page_size;

        $curr_id = $last_id;

        my $documents = $self->documents({
            $args->%*,
            last_id   => $last_id,
            page_size => $curr_page_size,
        });

        for my $doc ($documents->@*) {
            $last_id = $doc->{id};

            my $dir = join '/', $bundle, $country, $document_type, $status;

            my $file = join '/', $dir, $doc->{file_name};

            unless (-f $file) {
                my $blob = await $self->download($doc);

                next unless $blob;

                make_path($dir);

                open my $FH, '>', $file;
                print $FH $blob;
                close $FH;
            }

            push $files->{$country}->{$document_type}->{$status}->@*, $doc->{file_name};
        }

        $total -= scalar $documents->@*;

        last unless $last_id > $curr_id;
    }

    return $files;
}

=head2 download

Performs the download and allocation of the data into the bundle.

Takes a `betonmarkets.client_auhtentication_document` record as hashref, from which we are particuarly intersted into:

=over 4

=item C<file_name> - name of the file in the S3 bucket

=back

Returns a L<Future> which resolves to the binary blob of the file or C<undef> if there's been some error.

=cut

async sub download {
    my (undef, $doc) = @_;

    my ($file_name) = @{$doc}{qw/file_name/};

    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    my $url       = $s3_client->get_s3_url($file_name);

    my $http = HTTP::Tiny->new();

    my $response = $http->get($url);

    return $response->{content} if ($response->{status} // 0) == 200;

    return undef;
}

=head2 documents

Queries the DB for documents based on the arguments passed to the script, plus the list mentioned below:

=over 4

=item * C<page_size> - the number of records to get

=item * C<last_id> - pivot id to offset the query

=back

Returns an arrayref of `betonmarkets.client_authentication_document` records.

=cut

sub documents {
    my (undef, $args) = @_;

    my ($last_id, $page_size, $broker, $document_type, $status, $country, $side) =
        @{$args}{qw/last_id page_size broker document_type status country side/};

    my $db = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => 'replica',
        })->db->dbic;

    # Note the query is slightly different for sided documents
    # Also the approach might not be accurate, e.g.: there is no guarantee that every document has the uploaded counterpart

    if ($side) {
        return $db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    "SELECT * FROM betonmarkets.client_authentication_document doc WHERE doc.id > ? AND doc.file_name LIKE ? AND doc.document_type = ? AND doc.status = ? AND doc.issuing_country = ? ORDER BY doc.id ASC LIMIT ?",
                    {Slice => {}},
                    $last_id,
                    join('', '%', '_', $side, '.', '%'),    # there is no side column but we can like query by file name as: %_front.% or %_back.%
                    $document_type,
                    $status,
                    $country,
                    $page_size,
                );
            });
    }

    return $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM betonmarkets.client_authentication_document doc WHERE doc.id > ? AND doc.document_type = ? AND doc.status = ? AND doc.issuing_country = ? ORDER BY doc.id ASC LIMIT ?",
                {Slice => {}}, $last_id, $document_type, $status, $country, $page_size,
            );
        });
}

1;

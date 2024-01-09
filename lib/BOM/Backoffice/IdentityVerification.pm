package BOM::Backoffice::IdentityVerification;

use strict;
use warnings;

use Brands::Countries;
use BOM::Config;
use BOM::Database::UserDB;
use BOM::Backoffice::Request qw(request);
use JSON::MaybeUTF8          qw(decode_json_utf8);
use BOM::Platform::S3Client;

use constant PAGE_LIMIT => 30;

=head2 get_filter_data

Provides data to fill the IDV dashboard filters

=over 4

=item * C<countries> - Hashref of countries  

=item * C<document_types> - Hashref of document types

=item * C<providers> - Hashref of providers

=back

Returns the info needed to populate idv filters template, the resulting hashref contains
a hashref whose keys are the id's of each entity whereas the value is the "human readable" name:

=cut

sub get_filter_data {
    my $brand_countries_obj = Brands::Countries->new();
    my $config              = $brand_countries_obj->get_idv_config();
    my ($countries, $document_types, $providers, $statuses, $messages);

    $countries = +{map { ($_ => $brand_countries_obj->countries_list->{$_}->{name}) } keys $config->%*};

    $document_types = +{};
    foreach my $country_key (keys $config->%*) {
        my $country_config = $config->{$country_key};
        foreach my $document_type_key (keys $country_config->{document_types}->%*) {
            my $document_type = $document_type_key;
            my $display_name  = $country_config->{document_types}->{$document_type_key}->{display_name};

            unless (grep { $_ eq $display_name } @{$document_types->{$document_type}}) {
                push @{$document_types->{$document_type}}, $display_name;
            }
        }
    }

    my $idv_config = BOM::Config::identity_verification();

    $providers = +{
        map { ($_ => $idv_config->{providers}->{$_}->{display_name}); }
            keys $idv_config->{providers}->%*
    };

    $statuses = $idv_config->{statuses};
    $messages = $idv_config->{messages};

    return {
        countries      => $countries,
        document_types => $document_types,
        providers      => $providers,
        statuses       => $statuses,
        messages       => $messages,
    };
}

=head2 get_dashboard

Retrieves data for the IDV dashboard.

Use replica DB.

It takes the following parameters as hash (all optional):

=over 4

=item * C<country> - country of origin of the documents

=item * C<provider> - provider who made the verification

=item * C<date_from> - date range from 

=item * C<date_to> - date range to

=item * C<document_number> - document number to match

=item * C<loginid> - the client to match

=item * C<document_type> - document type

=item * C<status> - status of the verification

=item * C<message> - status message within the messages array of the verification

=back

Returns an arrayref of hashrefs.

=cut

sub get_dashboard {
    my %args = @_;

    if (my $loginid = $args{loginid}) {
        $args{loginid} = uc $loginid;

        return [] if $args{loginid} =~ /^VR/;    # virtual is pointless
    }

    my $rows = _query(%args);

    return _normalize($rows, $args{csv});
}

=head2 _query

Calls the DB function that gets the Dashboard data.

=cut

sub _query {
    my %args = @_;

    my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

    return $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM idv.get_idv_dashboard(?::TEXT, ?::TEXT, ?::DATE, ?::DATE, ?::TEXT, ?::idv.provider, ?::idv.check_status, ?::TEXT, ?::TEXT, ?::INT, ?::INT)",
                {Slice => {}},
                map { $_ || undef } @args{
                    qw/
                        loginid
                        document_number
                        date_from
                        date_to
                        country
                        provider
                        status
                        document_type
                        message
                        offset
                        /
                },
                PAGE_LIMIT + 1
            );
        });
}

=head2 _normalize

Apply transformation to the Dashboard data.

=cut

sub _normalize {
    my ($rows, $csv) = @_;

    my $photo_pot = {};

    for my $index (0 .. scalar $rows->@*) {
        my $row = $rows->[$index];

        $row->{loginids} =
            [map { $_ =~ /^VR/ ? () : +{loginid => $_, url => request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $_})} }
                $row->{loginids}->@*];

        $row->{status_messages} = decode_json_utf8($row->{status_messages} // '[]');

        if ($csv) {
            $row->{loginids}        = join('|', map { $_->{loginid} } $row->{loginids}->@*);
            $row->{status_messages} = join('|', $row->{status_messages}->@*);
        } else {
            # Point each photo id to their row index
            # csv does not need this
            $photo_pot = +{$photo_pot->%*, map { defined $_ ? ($_ => $index) : () } $row->{photo_id}->@*} if $row->{photo_id};
        }
    }

    # To grab the pictures we will hit the database only once and use the pot indexing to accommodate
    # them back into the rows.

    if (scalar keys $photo_pot->%*) {
        my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
        my $photo_ids = [keys $photo_pot->%*];
        my $documents = _documents_query($photo_ids);

        my $urls = +{map { $s3_client->get_s3_url($_->{file_name}) => $photo_pot->{$_->{id}} } $documents->@*};

        for my $url (keys $urls->%*) {
            my $index = $urls->{$url};
            $rows->[$index]->{photo_urls} //= [];
            push $rows->[$index]->{photo_urls}->@*, $url;
        }
    }

    return $rows;
}

=head2 _documents_query

Calls the DB function to grab pictures from the documents table.

Note: IDV is CR only, if we ever support another broke code we will have to refactor
the IDV photo_id storage and accomodate the broke code somewhere.

It takes the following parameters: 

=over 4

=item * C<$photo_ids> - and arrayref of documents ids representing the IDV pictures

=back

Returns an arrayref of the betonmarkets.client_authentication_document resultset.

=cut

sub _documents_query {
    my ($photo_ids) = @_;

    my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;

    return $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM betonmarkets.get_document_files(?::BIGINT[])", {Slice => {}}, $photo_ids);
        });
}

1;

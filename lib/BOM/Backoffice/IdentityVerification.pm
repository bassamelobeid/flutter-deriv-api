package BOM::Backoffice::IdentityVerification;

use strict;
use warnings;

use Brands::Countries;
use BOM::Config;
use BOM::Database::UserDB;
use BOM::Backoffice::Request qw(request);
use JSON::MaybeUTF8          qw(decode_json_utf8);

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

    $document_types = +{
        map {
            my $country_config = $config->{$_};

            (map { ($_ => $country_config->{document_types}->{$_}->{display_name}) } keys $country_config->{document_types}->%*);

        } keys $config->%*
    };

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

    for my $row ($rows->@*) {
        $row->{loginids} =
            [map { $_ =~ /^VR/ ? () : +{loginid => $_, url => request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $_})} }
                $row->{loginids}->@*];

        $row->{status_messages} = decode_json_utf8($row->{status_messages} // '[]');

        if ($csv) {
            $row->{loginids}        = join('|', map { $_->{loginid} } $row->{loginids}->@*);
            $row->{status_messages} = join('|', $row->{status_messages}->@*);
        }
    }

    return $rows;
}

1;

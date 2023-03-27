package BOM::Config::Onfido;

use strict;
use warnings;
use feature "state";

=head1 NAME

C<BOM::Config::Onfido>

=head1 DESCRIPTION

A module that consists methods to get config data related to Onfido.

=cut

use constant ONFIDO_SUPPORTED_DOCUMENTS_JSON => 'https://onfido.com/wp-content/themes/onfido/static/supported-documents.json';
use constant ONFIDO_REDIS_CONFIG_KEY         => 'ONFIDO::SUPPORTED::DOCUMENTS::';
use constant ONFIDO_REDIS_CONFIG_VERSION_KEY => 'ONFIDO::SUPPORTED_DOCUMENTS_VERSION';
use constant ONFIDO_SUPPORTED_DOCUMENTS_CODES => {
    PPO => 'Passport',
    NIC => 'National Identity Card',
    DLD => 'Driving Licence',
    REP => 'Residence Permit',
    VIS => 'Visa',
    HIC => 'National Health Insurance Card',
    ARC => 'Asylum Registration Card',
    ISD => 'Immigration Status Document',
    VTD => 'Voter Id',
};

use JSON::MaybeUTF8        qw(:v1);
use Locale::Codes::Country qw(country_code2code);

use Log::Any qw($log);
use BOM::Config;
use HTTP::Tiny;
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use BOM::Config::Redis;
use YAML::XS                   qw(DumpFile);
use DataDog::DogStatsd::Helper qw(stats_event);

=head2 supported_documents_list

Returns an array of hashes of supported_documents for each country

=cut

sub supported_documents_list {
    my $supported_documents = BOM::Config::onfido_supported_documents();
    my $redis               = BOM::Config::Redis::redis_replicated_read();

    # inject the data from Redis here if available
    if ($redis->get(ONFIDO_REDIS_CONFIG_VERSION_KEY)) {
        my %doc_mapping = %{ONFIDO_SUPPORTED_DOCUMENTS_CODES()};

        return [
            map {
                my $doc_types_list = $_->{doc_types_list};
                my $docs           = $redis->smembers(ONFIDO_REDIS_CONFIG_KEY . $_->{country_code});

                # override the list from the yml from the redis set of the country
                # also translate the code into the proper common name
                $doc_types_list = [sort map { $doc_mapping{$_} // () } $docs->@*];

                +{
                    $_->%*,
                    doc_types_list => $doc_types_list,
                }
            } $supported_documents->@*
        ];
    }

    return $supported_documents;
}

=head2 supported_documents_for_country

Takes the following argument(s) as parameters:

=over 4

=item * C<$country_code> - The ISO code of the country

=back

Example:

    my $supported_docs_my = BOM::Config::Onfido::support_documents_for_country('my');

Returns the supported_documents_list for the country.

=cut

sub supported_documents_for_country {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');
    return [] unless $country_code;

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{doc_types_list} // [];
}

=head2 is_country_supported

Returns 1 if country is supported and 0 if it is not supported

=cut

sub is_country_supported {
    my $country_code = shift;

    return 0 if is_disabled_country($country_code);

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{doc_types_list} ? 1 : 0;
}

=head2 is_disabled_country

Returns 1 if the country is disabled, 0 otherwise.

=cut

sub is_disabled_country {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '') if (length($country_code) == 2);

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{disabled} ? 1 : 0;
}

=head2 _get_country_details

Changes the format into hash

=cut

{
    # private variable to cache the current settings
    # but writable by the sub below to hit a new version
    my $country_details;

    sub _get_country_details {
        my $redis        = BOM::Config::Redis::redis_replicated_read();
        my $conf_version = $redis->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // '';

        if ($country_details) {
            my $curr_version = $country_details->{version} // '';

            # clear the list if the version changed
            $country_details = undef if $conf_version && ($conf_version ne $curr_version);
        }

        $country_details //= {
            version => $conf_version,
            details => +{map { $_->{country_code} => $_ } @{supported_documents_list()}},
        };

        return $country_details->{details};
    }
}

=head2 supported_documents_updater

Fetches, parses and dumps the Onfido supported documents json into Redis.

If an exception occurs we keep the last version.

=cut

sub supported_documents_updater {
    my $doc_stash   = {};
    my %doc_mapping = %{ONFIDO_SUPPORTED_DOCUMENTS_CODES()};

    try {
        my $redis    = BOM::Config::Redis::redis_replicated_write();
        my $response = HTTP::Tiny->new->get(ONFIDO_SUPPORTED_DOCUMENTS_JSON);
        my $status   = $response->{status} // '0';

        die "status=$status" unless $status == 200;

        my $json    = decode_json($response->{content});
        my $data    = $json->{data} // [];
        my $meta    = $json->{meta} // {};
        my $version = $meta->{version};

        return unless $version;

        my $curr_version = $redis->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // '';

        return unless $version ne $curr_version;

        # clear the settings
        my @redis_keys = $redis->scan_all(MATCH => ONFIDO_REDIS_CONFIG_KEY . '*')->@*;

        $redis->multi;
        $redis->del(ONFIDO_REDIS_CONFIG_VERSION_KEY, @redis_keys);

        for my $doc ($data->@*) {
            my $country_alpha3 = $doc->{country_alpha3} or next;
            my $document_type  = $doc->{document_type}  or next;

            $doc_stash->{$country_alpha3} //= +{};
            $doc_stash->{$country_alpha3}->{$document_type} = 1 if $doc_mapping{$document_type};
        }

        for my $country_alpha3 (keys $doc_stash->%*) {
            next unless scalar keys $doc_stash->{$country_alpha3}->%*;
            $redis->sadd(ONFIDO_REDIS_CONFIG_KEY . $country_alpha3, keys $doc_stash->{$country_alpha3}->%*);
        }

        $redis->set(ONFIDO_REDIS_CONFIG_VERSION_KEY, $version);
        $redis->exec;

        stats_event('Onfido Supported documents', "updated to version $version", {alert_type => 'success'});
    } catch ($e) {
        stats_event('Onfido Supported documents', 'failed to process the update', {alert_type => 'error'});

        $log->errorf('Failed to update Onfido supported documents - %s', $e);
    }
}

1;

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
use constant ONFIDO_REDIS_DOCUMENTS_KEY      => 'ONFIDO::SUPPORTED::DOCUMENTS::STASH';
use constant ONFIDO_REDIS_CONFIG_VERSION_KEY => 'ONFIDO::SUPPORTED_DOCUMENTS_VERSION';
use constant ONFIDO_SUPPORTED_DOCUMENTS_CODES => {
    PPO => 'Passport',
    NIC => 'National Identity Card',
    IND => 'Identification Number Document',
    SIC => 'Service Identity Card',
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
use HTTP::Tiny;
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use YAML::XS                   qw(DumpFile);
use DataDog::DogStatsd::Helper qw(stats_event);
use List::Util                 qw(uniq);
use JSON::MaybeXS              qw(encode_json decode_json);

use BOM::Config;
use BOM::Config::Redis;
use Business::Config;

=head2 supported_documents_list

Returns an array of hashes of supported_documents for each country

=cut

sub supported_documents_list {
    try {
        my $redis_replicated = BOM::Config::Redis::redis_replicated_read();
        my $redis            = BOM::Config::Redis::redis_events();

        # override with data from Redis here if available
        if (my $json = $redis->get(ONFIDO_REDIS_DOCUMENTS_KEY) // $redis_replicated->get(ONFIDO_REDIS_DOCUMENTS_KEY)) {
            return decode_json($json);
        }
    } catch ($e) {
        $log->warnf('Could not read Onfido supported documents from redis key: %s', ONFIDO_REDIS_DOCUMENTS_KEY);
    }

    # fallback to static yml
    return Business::Config->new()->onfido_supported_documents();
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

=head2 onfido_data_for_all_countries

Gets supported Onfido documents and that if Onfido is supported for all countries.

Returns a hashref of the following structure for every 2-letter country_code.

=over 4

=item * C<supported_documents> - List of documents supported by Onfido for the country

=item * C<is_supported> - 0 if the country not supported, 1 if supported.

=back

=cut

sub onfido_data_for_all_countries {
    my $onfido_disabled_countries = Business::Config->new()->onfido_disabled_countries();
    my $countries_instance        = Brands::Countries->new();

    my %hash            = ();
    my $country_details = _get_country_details();
    foreach my $country_code (keys $countries_instance->countries_list->%*) {
        my $country_code_3chars = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');
        if ($country_code_3chars) {
            my @supported_documents = $country_details->{$country_code_3chars}->{doc_types_list} // [];
            $hash{$country_code} = {
                supported_documents => @supported_documents,
                is_supported        => _check_is_country_supported(
                    country_code              => $country_code,
                    country_details           => $country_details,
                    country_code_3chars       => $country_code_3chars,
                    onfido_disabled_countries => $onfido_disabled_countries
                )};
        } else {
            $hash{$country_code} = {
                supported_documents => [],
                is_supported        => 0
            };
        }
    }
    return \%hash;
}

=head2 is_country_supported

Returns 1 if country is supported and 0 if it is not supported

=cut

sub is_country_supported {
    return _check_is_country_supported(country_code => shift);
}

=head2 _check_is_country_supported

Returns 1 if country is supported and 0 if it is not supported. It is better to call this one
if precalculated values for the optional parameters are available as it saves Redis reads and 
improves performance

It takes the following parameters as a hash:

=over 4

=item * C<country_code> the 2-letter country code

=item * C<onfido_disabled_countries> (optional) the data returned by Business::Config#onfido_disabled_countries

=item * C<country_details> (optional) the data from Redis retrieved by L</_get_country_details>

=item * C<country_code_3chars> (optional) the 3-letter country code corresponding to the 2-letter one passed in

=back

=cut

sub _check_is_country_supported {
    my %args    = @_;
    my @arg_arr = @args{qw(country_code onfido_disabled_countries country_details country_code_3chars)};

    my ($country_code, $onfido_disabled_countries, $country_details, $country_code_3chars) = @arg_arr;
    return 0 if is_disabled_country($country_code, $onfido_disabled_countries);

    $country_details                                           //= _get_country_details();
    $country_code_3chars                                       //= uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');
    $country_details->{$country_code_3chars}->{doc_types_list} //= [];
    my $has_documents = scalar $country_details->{$country_code_3chars}->{doc_types_list}->@*;
    return $has_documents ? 1 : 0;
}

=head2 is_disabled_country

Returns 1 if the country is disabled, 0 otherwise.

It takes the following parameters:

=over 4

=item * C<country_code> the 2-letter country code

=item * C<country_details> (optional) the data from Redis retrieved by L</_get_country_details>

=back

=cut

sub is_disabled_country {
    my ($country_code, $country_details) = @_;

    # in current implementation the yml might be overriden by the automatic update,
    # an so we need a different place to store disabled countries
    $country_details //= Business::Config->new()->onfido_disabled_countries();

    $country_details->{$country_code} //= 0;
    return $country_details->{$country_code} ? 1 : 0;
}

=head2 _get_country_details

Changes the format into hash

=cut

{
    # private variable to cache the current settings
    # but writable by the sub below to hit a new version
    my $country_details;

    sub _get_country_details {
        my %args             = @_;
        my $redis_replicated = BOM::Config::Redis::redis_replicated_read();
        my $redis            = BOM::Config::Redis::redis_events();
        my $conf_version     = $redis->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // $redis_replicated->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // '';

        if ($args{overwrite} || !$country_details) {
            # would be nice to have a lock here, maybe?
            $country_details = {
                version => $conf_version,
                details => +{map { $_->{country_code} => $_ } @{supported_documents_list()}},
            };
        } elsif ($country_details) {
            my $curr_version = $country_details->{version} // '';

            # overwrite the list if the version has changed
            return _get_country_details(overwrite => 1) if $conf_version && ($conf_version ne $curr_version);
        }

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
        my $redis_replicated = BOM::Config::Redis::redis_replicated_write();
        my $redis            = BOM::Config::Redis::redis_events_write();
        my $response         = HTTP::Tiny->new->get(ONFIDO_SUPPORTED_DOCUMENTS_JSON);
        my $status           = $response->{status} // '0';

        die "status=$status" unless $status == 200;

        my $json    = decode_json($response->{content});
        my $data    = $json->{data} // [];
        my $meta    = $json->{meta} // {};
        my $version = $meta->{version};

        return unless $version;

        my $curr_version = $redis->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // $redis_replicated->get(ONFIDO_REDIS_CONFIG_VERSION_KEY) // '';

        return unless $version ne $curr_version;

        for my $doc ($data->@*) {
            my $country_alpha3 = $doc->{country_alpha3} or next;
            my $document_type  = $doc->{document_type}  or next;
            my $country        = $doc->{country}        or next;

            # note country_grouping is not used anywhere
            # and so we could save some bytes
            $doc_stash->{$country_alpha3} //= +{
                country_name   => $country,
                doc_types_list => [],
            };

            push $doc_stash->{$country_alpha3}->{doc_types_list}->@*, $doc_mapping{$document_type} if $doc_mapping{$document_type};
        }

        my $document = [
            map {
                $doc_stash->{$_}->{doc_types_list} = [sort { $a cmp $b } uniq $doc_stash->{$_}->{doc_types_list}->@*];

                +{
                    country_code => $_,
                    $doc_stash->{$_}->%*,
                }
            } sort keys $doc_stash->%*
        ];

        $redis_replicated->multi;
        $redis_replicated->set(ONFIDO_REDIS_CONFIG_VERSION_KEY, $version);
        $redis_replicated->set(ONFIDO_REDIS_DOCUMENTS_KEY,      encode_json($document));
        $redis_replicated->exec;

        $redis->multi;
        $redis->set(ONFIDO_REDIS_CONFIG_VERSION_KEY, $version);
        $redis->set(ONFIDO_REDIS_DOCUMENTS_KEY,      encode_json($document));
        $redis->exec;

        stats_event('Onfido Supported documents', "updated to version $version", {alert_type => 'success'});
    } catch ($e) {
        stats_event('Onfido Supported documents', 'failed to process the update', {alert_type => 'error'});

        $log->errorf('Failed to update Onfido supported documents - %s', $e);
    }
}

=head2 clear_supported_documents_cache

Clears the supported documents cache.

=cut

sub clear_supported_documents_cache {
    my $redis_replicated = BOM::Config::Redis::redis_replicated_write();
    my $redis            = BOM::Config::Redis::redis_events();

    $redis_replicated->del(ONFIDO_REDIS_DOCUMENTS_KEY);
    $redis->del(ONFIDO_REDIS_DOCUMENTS_KEY);
    $redis_replicated->del(ONFIDO_REDIS_CONFIG_VERSION_KEY);
    $redis->del(ONFIDO_REDIS_CONFIG_VERSION_KEY);
}

1;

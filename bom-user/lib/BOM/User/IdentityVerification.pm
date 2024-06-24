package BOM::User::IdentityVerification;

=head1 DESCRIPTION

Identity Verification services DB wrapper and utilities.

Note this module is meant to be decoupled from L<BOM::User> or L<BOM::User::Client>.

=cut

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeUTF8 qw(:v2);
use Syntax::Keyword::Try;
use Log::Any   qw($log);
use List::Util qw(any);

use BOM::Platform::Context qw(request localize);
use BOM::Platform::Utility;
use BOM::Config::Redis;
use BOM::Database::UserDB;
use Moo;

use constant IDV_LOCK_PENDING               => 'IDV::LOCK::PENDING::';
use constant IDV_REQUEST_PENDING_TTL        => 86400;                                       # one day in second
use constant IDV_REQUEST_PER_USER_PREFIX    => 'IDV::REQUEST::PER::USER::';
use constant IDV_EXPIRED_CHANCE_USED_PREFIX => 'IDV::EXPIRED::CHANCE::USED::';
use constant ONE_WEEK                       => 604_800;
use constant IDV_CONFIGURATION_OVERRIDE     => 'IDV::CONFIGURATION::OVERRIDE::DISABLE::';

=head2 user_id

The current IDV user.

=cut

has user_id => (
    is       => 'ro',
    required => 1,
);

=head2 add_document

Add document row filled by provided info by user

It takes a hashref argument:

=over 4

=item * C<issuing_country> - the document issuing country

=item * C<number> - the number of document, can be letters and numbers or combination of them

=item * C<type> - the type of document

=item * C<expiration_date> - nullable, the document expiry date

=item * C<additional> - (optional) additional info

=back

Returns arrayref.

=cut

sub add_document {
    my ($self, $args) = @_;

    my ($issuing_country, $document_number, $document_type, $expiration_date, $document_additional) =
        @{$args}{qw/issuing_country number type expiration_date additional/};

    die 'issuing_country is required' unless $issuing_country;
    die 'document_number is required' unless $document_number;
    die 'document_type is required'   unless $document_type;

    $expiration_date = validate_date_format($expiration_date);

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.add_document(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT)',
                    undef, $self->user_id, $issuing_country, $document_number, $document_type, $expiration_date, $document_additional);
            });
    } catch ($e) {
        die sprintf("Failed while adding document due to '%s'", $e);
    }

    return;
}

=head2 get_claimed_documents

Gets a list of documents with the same criteria but might uploaded by different users.

=over 4

=item * C<$issuing_country> - the document issuing country

=item * C<$document_number> - the number of document, can be letters and numbers or combination of them

=item * C<$document_type> - the type of document

=back

Returns arrayref or undef

=cut

sub get_claimed_documents {
    my ($self, $args) = @_;

    my ($issuing_country, $document_number, $document_type) = @{$args}{
        qw/
            issuing_country   number            type
            /
    };

    die 'issuing_country is required' unless $issuing_country;
    die 'document_number is required' unless $document_number;
    die 'document_type is required'   unless $document_type;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM idv.get_claimed_documents(?::TEXT, ?::TEXT, ?::TEXT)',
                    {Slice => {}},
                    $issuing_country, $document_type, $document_number
                );
            });
    } catch ($e) {
        die sprintf("Failed while getting claimed documents due to '%s'", $e);
    }

    return;
}

=head2 get_standby_document

Gets last standby document added by user

=cut

sub get_standby_document {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_standby_document(?::BIGINT)', undef, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting standby document for IDV process, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 update_document_check

Updates status on idv.document and try to update
details in idv.document_check otherwise will
create new row for details.

=over 4

=item * C<$document_id> - the id of document to which this record belongs

=item * C<$status> - the status of check

=item * C<$message> - the message for status

=item * C<$provider> - the third-party provider which we use for IDV

=item * C<$report> - nullable,  a summary of provider response in unified structure

=item * C<$request_body> - nullable, the request body we sent to provider

=item * C<$response_body> - nullable, the response we received from provider

=item * C<$expiration_date> - nullable, the document expiry date

=item * C<$photo> - nullable, photo id for idv check if available

=back

Returns void.

=cut

sub update_document_check {
    my ($self, $args) = @_;

    my ($document_id, $status, $messages, $provider, $report, $request_body, $response_body, $expiration_date, $photo_id) = @{$args}{
        qw/
            document_id   status   messages   provider  report  request_body   response_body   expiration_date photo
            /
    };

    die 'document_id is required' unless $document_id;

    if (ref $messages eq 'ARRAY') {
        for my $msg ($messages->@*) {
            unless (defined $msg) {
                $log->warnf('IdentityVerification is pushing a NULL status message, document_id=%d, provider=%s', $document_id, $provider);
            }
        }
    }

    # should've already been utf8 decoded
    $messages        = encode_json_text($messages) if $messages;
    $expiration_date = validate_date_format($expiration_date);

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    $photo_id = [$photo_id] if $photo_id && ref($photo_id) ne 'ARRAY';

    $photo_id //= [];

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'SELECT FROM idv.update_document_check(?::BIGINT, ?::idv.provider, ?::idv.check_status, ?::JSONB, ?::JSONB, ?::JSONB, ?::JSONB, ?::TIMESTAMP, ?::BIGINT[])',
                    undef, $document_id, $provider, $status, $messages, $report, $request_body, $response_body, $expiration_date, $photo_id
                );
            });
    } catch ($e) {
        die sprintf("Failed while updating document_check due to '%s', for document_id: %s", $e, $document_id);
    }

    return;
}

=head2 get_last_updated_document

Gets the document information which has been updated recently.

=cut

sub get_last_updated_document {
    my $self = shift;
    my $args = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_last_updated_document(?::BIGINT, ?::BOOL)',
                    undef, $self->user_id, $args->{only_verified} ? 1 : 0);
            });
    } catch ($e) {
        die sprintf("Failed while getting last IDV updated document, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 get_document_check_detail

Gets the checks details for the given document information which has been updated recently.

=over 4

=item * C<$document_id> - the id of document

=back

=cut

sub get_document_check_detail {
    my ($self, $document_id) = @_;

    die 'ARGUMENT #1: document_id is required' unless $document_id;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_document_check(?::BIGINT)', undef, $document_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting document check detail, check user_id: %s", $self->user_id);
    }

    return;
}

=head2 get_rejected_reasons

Parses and extract the latest IDV rejection reasons for the current user.

Returns,
    an arrayref of possible reasons why the IDV attempt has been rejected

=cut

sub get_rejected_reasons {
    return [];    # TODO: proper implementation
}

=head2 submissions_left

Returns the submissions left for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub submissions_left {
    my $self = shift;

    my $redis            = BOM::Config::Redis::redis_events();
    my $request_per_user = $redis->get(IDV_REQUEST_PER_USER_PREFIX . $self->user_id) // 0;
    my $submissions_left = limit_per_user() - $request_per_user;

    return $submissions_left;
}

=head2 has_expired_document_chance

Determines whether the expired doc chance has been used for this week.

=cut

sub has_expired_document_chance {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events_write();

    return !$redis->get(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);
}

=head2 claim_expired_document_chance

Claims the expired document chance by writing the redis lock for one week.

=cut

sub claim_expired_document_chance {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events_write();

    return $redis->set(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id, 1, 'EX', ONE_WEEK);
}

=head2 expired_document_chance_ttl

Gets the TTL for the expired document chance reset.

=cut

sub expired_document_chance_ttl {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    # will return -2 when the keys does not exists
    # will return -1 when the keys exists but no expiration was defined
    # otherwise will return the ttl in seconds.
    return $redis->ttl(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);
}

=head2 incr_submissions

Increments the submissions for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub incr_submissions {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();
    my $left  = $self->submissions_left();

    # do not go beyond the limit
    return unless $left > 0;

    $redis->incr(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 reset_attempts

Get the attempts of the client back.

=cut

sub reset_attempts {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    # Reset the expired docs chance
    $redis->del(IDV_EXPIRED_CHANCE_USED_PREFIX . $self->user_id);

    return $redis->del(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 decr_submissions

Decrements the submissions for the user.

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub decr_submissions {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    $redis->decr(IDV_REQUEST_PER_USER_PREFIX . $self->user_id);
}

=head2 reset_to_zero_left_submissions 

Reset left submissions count to zero equaivalent of disabling the IDV system.

=cut

sub reset_to_zero_left_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(IDV_REQUEST_PER_USER_PREFIX . $user_id, limit_per_user());
}

=head2 limit_per_user

Provides a central point for idv resubmissions limit per user in the specified
timeframe.

Returns,
    an integer representing the idv submission requests allowed per user

=cut

sub limit_per_user {
    return $ENV{IDV_REQUEST_PER_USER_LIMIT} // 2;
}

=head2 reported_properties

Returns the user detected properties, from the latest IDV request, as a hashref.

It takes the following arguments:

Returns a hashref containing detected properties.

=cut

sub reported_properties {
    return {};    # TODO: proper implementation
}

=head2 status

Computes the current IDV status of the latest document uploaded 
or of the document which was passed to this sub as an argument

=over 4

=item C<$self> - Current class

=item C<$document> - Document to check it's status if provided

=back

Returns the mapped status. 

=cut

sub status {
    my ($self, $document) = @_;

    # if lock exists return pending right away

    return 'pending' if ($self->get_pending_lock() // 0) > 0;

    $document //= $self->get_last_updated_document();

    return 'none' unless $document;

    my $status_mapping = {
        refuted  => 'rejected',
        failed   => 'rejected',
        pending  => 'pending',
        verified => 'verified',
        deferred => 'pending',
    };

    my $expiration_date;
    $expiration_date = Date::Utility->new($document->{document_expiration_date})->epoch if $document->{document_expiration_date};

    my $idv_status = $document->{status};
    my $status     = $status_mapping->{$idv_status} // 'none';
    $status = 'expired' if defined $expiration_date && time > $expiration_date;

    return $status;
}

=head2 get_document_check

Gets the the document check related to the given document.

=cut

sub get_document_check {
    my ($self, $document_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM idv.get_document_check(?::BIGINT)', undef, $document_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting document check for IDV process, document_id: %s, error: %s", $document_id, $e);
    }

    return undef;
}

=head2 get_document_check_list

Gets the document check list in chronological descending order for the current user.

=cut

sub get_document_check_list {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM idv.get_document_check_list(?::BIGINT)', {Slice => {}}, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting the document chec list for IDV process, check user_id: %s, error: %s", $self->user_id, $e);
    }
}

=head2 get_document_list

Gets the document list in chronological descending order for the current user.

=cut

sub get_document_list {
    my $self = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM idv.get_document_list(?::BIGINT)', {Slice => {}}, $self->user_id);
            });
    } catch ($e) {
        die sprintf("Failed while getting the document list for IDV process, check user_id: %s, error: %s", $self->user_id, $e);
    }
}

=head2 is_idv_disallowed

Checks whether client allowed to verify identity via IDV based on some business rules

=over 4

=item * C<client> a L<BOM::User::Client> instance.

=item * C<landing_company> (optional) landing company. Default: client's landing company.

=back

Returns 1 if IDV is disallowed, 0 otherwise.

=cut

sub is_idv_disallowed {
    my $args = shift;
    my ($client, $landing_company) = @{$args}{qw/client landing_company/};

    my $lc = $landing_company ? LandingCompany::Registry->by_name($landing_company) : $client->landing_company;

    # IDV allowed only for non-regulated LC
    return 1 unless any { $_ eq 'idv' } $lc->allowed_poi_providers->@*;

    return 1 if $client->status->unwelcome;

    return 1 if ($client->aml_risk_classification // '') eq 'high';

    return 1 if $client->status->age_verification && $client->get_idv_status() ne 'expired';
    return 1 if $client->status->allow_poi_resubmission;

    if ($client->status->allow_document_upload) {
        my $manual_status = $client->get_manual_poi_status();
        return 1 if $manual_status eq 'expired' or $manual_status eq 'rejected';

        my $onfido_status = $client->get_onfido_status();
        return 1 if $onfido_status eq 'expired' or $onfido_status eq 'rejected';
    }

    return 0;
}

=head2 identity_verification_requested

Fires the event to perform the applicant check request.

This function will also take care of counter increasing and everything
that the frontend may need to properly render the POI page.

It takes:

=over 4

=item * C<$client> - a client instance

=back

Returns C<0> - if there is a pending idv doc
Returns C<1> - if there is no pending idv doc

=cut

sub identity_verification_requested {
    my ($self, $client) = @_;
    my $redis = BOM::Config::Redis::redis_events();

    unless ($redis->set(IDV_LOCK_PENDING . $self->user_id, $self->submissions_left, 'NX', 'EX', IDV_REQUEST_PENDING_TTL)) {
        # using submissions_left as the lock value to consume al 3 submissions available for idv
        # this should not happen as we'd expect the frontend to block further requests
        $log->warnf('Unexpected IDV request when pending flag is still alive, user: %d', $self->user_id);
        return 0;
    }

    $self->incr_submissions();

    BOM::Platform::Event::Emitter::emit(
        identity_verification_requested => {
            loginid => $client->loginid,
        });

    return 1;
}

=head2 remove_lock

Removes the IDV request pending lock

=cut

sub remove_lock {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    $redis->del(IDV_LOCK_PENDING . $self->user_id);
}

=head2 get_pending_lock

Retrieves the IDV request pending lock, that should be the number of submissions left at lock time

=cut

sub get_pending_lock {
    my $self  = shift;
    my $redis = BOM::Config::Redis::redis_events();

    return $redis->get(IDV_LOCK_PENDING . $self->user_id);
}

=head2 is_idv_revoked

Boolean that determines if the client has been authenticated by IDV, but then it got it taken away due to
some restrictions like being high risk.

It takes the following parameter:

=over 4

=item * C<$client> - a L<BOM::User::Client> instance

=back

Returns boolean.

=cut

sub is_idv_revoked {
    my ($client) = @_;

    return 1 if $client->is_idv_validated && $client->get_idv_status eq 'verified' && $client->get_poi_status ne 'verified';

    return 0;
}

=head2 is_underage_blocked

Calls the DB function that determines if a given document has been underage blocked the last year.

It takes a hashref as parameteres:

=over

=item * C<issuing_country> - country of the document

=item * C<number> - number of the document

=item * C<type> - type of the document

=item * C<additional> - (optional) additional document numbers

=back

Returns C<undef> if not underage blocked, a binary user id from the the underage document otherwise.

=cut

sub is_underage_blocked {
    my (undef, $args) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my ($binary_user_id) = $dbic->run(
        fixup => sub {
            $_->selectrow_array(
                'SELECT idv.is_underage_blocked(?::TEXT , ?::TEXT, ?::TEXT, ?::TEXT)',
                {Slice => {}},
                @{$args}{qw/issuing_country number type additional/});
        });

    return $binary_user_id;
}

=head2 add_opt_out

Add row to idv.opt_out table.
Note: Currently, opting out of IDV has no side-effects.

It takes an argument:

=over 4

=item * C<country> - the IDV country client opted out of

=back

Returns void.

=cut

sub add_opt_out {
    my ($self, $country) = @_;

    die 'country is required' unless $country;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        $dbic->run(
            fixup => sub {
                $_->do('SELECT * FROM idv.add_opt_out(?::BIGINT, ?::TEXT)', undef, $self->user_id, $country);
            });
    } catch ($e) {
        die sprintf("Failed while adding opt out due to '%s'", $e);
    }

    return;
}

=head2 is_available

Checks if IDV service is available for the client.

It takes the following params as a hashref:

=over 4

=item * C<client> a L<BOM::User::Client> instance.

=item * C<landing_company> (optional) landing company. Default: client's landing company.

=item * C<country> (optional) 2-letter country code.

=back

Returns,
    1 if IDV is available for the client
    0 if IDV is not available for the client

IDV is available for the client if the IDV service is available, IDV is not disallowed, and:
    - has IDV submissions left or
    - has no IDV submissions left, IDV status is 'expired', and 
        has document expired chance

=cut

sub is_available {
    my ($self, $args) = @_;
    my $client       = $args->{client};
    my $country_code = $args->{country};

    my $countries_instance = Brands::Countries->new();
    my $idv_config         = $countries_instance->get_idv_config($country_code) // {};

    return 0 unless !$country_code || BOM::Platform::Utility::has_idv(
        country  => $country_code,
        provider => $idv_config->{provider});

    my $has_submissions_left = $self->submissions_left() > 0;

    my $expired_document_chance;
    $expired_document_chance = $self->has_expired_document_chance() ? 1 : 0
        if !$has_submissions_left && $client->get_idv_status() eq 'expired';

    my $idv_disallowed = is_idv_disallowed($args);

    my $is_available = ($has_submissions_left || $expired_document_chance) && !$idv_disallowed;

    return $is_available ? 1 : 0;
}

=head2 validate_date_format

Checks if the argument is a valid date.

It takes an argument:

=over 4

=item * C<$expiration_date> - the document expiration date

=back

Returns a Date::Utility date in case of a valid date or undef otherwise.

=cut

sub validate_date_format {
    my ($date_string) = @_;

    if (not defined $date_string or $date_string eq 'Not Available') {
        return undef;
    }

    my $eval_result;
    $eval_result = eval {
        $date_string = Date::Utility->new($date_string)->date;
        1;
    };

    $date_string = undef unless $eval_result;

    return $date_string;
}

=head2 supported_documents

Gets the supported IDV document types for the provided country.

It takes the following parameter:

=over 4

=item * C<country> 2-letter country code.

=back

Returns a hashref containing the information for each document type:

=over 4

=item * C<display_name> - document type display name.

=item * C<format> - document type number format.

=item * C<additional> (optional) document type additional information.

=back

=cut

sub supported_documents {
    my $country_code = shift;

    my $countries_instance = Brands::Countries->new();
    my $idv_config         = $countries_instance->get_idv_config($country_code) // {};

    return _supported_documents_for_country_config($country_code, $idv_config);
}

=head2 _supported_documents_for_country_config

Returns the IDV supported document types given a country from the provided idv_config. 
It is merely to reuse the idv_config, instead of fetching it for every call.

The parameters are:

=over 4

=item * C<country> 2-letter country code

=item * C<idv_config> the idv_config data returned from Brands::Countries

=back

Returns the same information as L<supported_documents|/supported_documents>

=cut

sub _supported_documents_for_country_config {
    my ($country_code, $idv_config, $lookup_has_idv) = @_;
    $lookup_has_idv //= BOM::Platform::Utility::has_idv_all_countries(
        country             => $country_code,
        index_with_doc_type => 1
    );
    my $idv_docs_supported = $idv_config->{document_types} // {};
    return +{
        map {
            (
                $_ => {
                    display_name => localize($idv_docs_supported->{$_}->{display_name}),
                    format       => $idv_docs_supported->{$_}->{format},
                    $idv_docs_supported->{$_}->{additional} ? (additional => $idv_docs_supported->{$_}->{additional}) : (),
                })
        } grep { !$idv_docs_supported->{$_}->{disabled} && $lookup_has_idv->{"$country_code:$_"} }
            keys $idv_docs_supported->%*
    };
}

=head2 supported_documents_all_countries
Returns the IDV supported document types for all countries. 

Returns a hashref of hashrefs with the following information for each document type for each 2-letter country code:

=over 4

=item * C<display_name> - document type display name.

=item * C<format> - document type number format.

=item * C<additional> (optional) document type additional information.

=back

=cut

sub supported_documents_all_countries {
    my $countries_instance = Brands::Countries->new();
    my $idv_config_all     = $countries_instance->get_idv_config() // {};
    my $has_idv_lookup     = BOM::Platform::Utility::has_idv_all_countries(index_with_doc_type => 1);
    return +{
        map { ($_ => _supported_documents_for_country_config($_, $idv_config_all->{$_}, $has_idv_lookup)) }
            keys $countries_instance->countries_list->%*
    };
}

1;

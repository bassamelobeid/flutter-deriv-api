package BOM::User::Client::AuthenticationDocuments;

use strict;
use warnings;
use Moo;

use List::Util   qw(first any min max);
use Array::Utils qw(intersect);

use Path::Tiny;
use YAML::XS;
use Dir::Self;
use BOM::Config::Redis;
use Date::Utility;

use constant POA_ADDRES_MISMATCH_TTL  => 604_800;
use constant POA_ADDRESS_MISMATCH_KEY => 'POA_ADDRESS_MISMATCH::';
use constant MAX_UPLOAD_TRIES_PER_DAY => 20;
use constant MAX_UPLOADS_KEY          => 'MAX_UPLOADS_KEY::';

use constant DOCUMENT_EXPIRING_SOON_DAYS_TO_LOOK_AHEAD => 90;
use BOM::User::Client::AuthenticationDocuments::Config;

=head1 NAME

BOM::User::Client::AuthenticationDocuments - A class that manages the client authentication documents and related logic.

=cut

=head2 client

The C<BOM::User::Client> instance, although it feels incovenient to carry the whole object,
Rose is both the poison and the antidote I guess. 

=cut

has client => (
    is       => 'ro',
    required => 1,
    weak_ref => 1,
);

=head2 categories

Lazily loads the document_type_categories.yml configuration file 

Returns a hashref containing all the document categories and types available in our current config.

=cut

has categories => (
    is      => 'lazy',
    clearer => '_clear_categories',
);

=head2 _build_categories

It builds and returns the categories hashref from document_type_categories.yml

Each section of the hashref correspond to a specific category of documents (POI, POA)

These categories may have the following structure:

=over 4

=item * C<description> a human readable and brief description of the category (used in the backoffice dropdowns)

=item * C<category> the `documents->uploaded` version of the category name, used mainly by the `uploaded` method, defaults to `other`.

=item * C<expiration_strategy> a string that indicates which strategy of expiration the category will take: `min` or `max`.

=item * C<sides_required> a boolean that indicates whether the side of the document is required for uploading.

=item * C<priority> a integer value that denotes the intrinsic hierarchy of the categories (used in the backoffice dropdowns for sorting purposes)

=item * C<types> a hashref with the document types enclosed in this category

=back

The `types` hashref has its own structure for each document type:

=over 4

=item C<preferred> A flag that indicates whether the document should be taken into account for validation purposes, defaults to false

=item C<description> A human readable and brief description of the type (used in the backoffice dropdowns)

=item C<date> A string that indicates how we should interpret the date attached to the document, can be `expiration`, `issuance` or `none`. 

=item C<priority> A integer value that denotes the intrinsic hierarchy of the types within its category (used in the backoffice dropdowns for sorting purposes)

=item C<deprecated> A flag that indicates we should stop using this type for newly uploaded documents, this type may still be subjected to validations for backwards compatibility though (see preferred)

=back

Returns a hashref for the document categories

=cut

sub _build_categories {
    my ($self) = @_;

    return BOM::User::Client::AuthenticationDocuments::Config::categories();
}

=head2 uploaded

Lazily loads the client uploaded documents.

Returns a hashref containing a breakdown of documents by category.

=cut

has uploaded => (
    is      => 'lazy',
    clearer => '_clear_uploaded',
);

=head2 _build_uploaded

Gets the uploaded documents in a fancy hashref structure, the scan is made upon the current client and
its siblings, will discard documents not in the `uploaded` status. 

Each key corresponds to a category of documents (e.g. proof_of_identity, proof_of_address, proof_of_income) 
Note that `onfido` is a special separate category.
It may contain:

=over 4

=item * C<documents> a hashref containing each individual document by file name.

=item * C<is_expired> a flag that indicates whether the client has expired documents, note this flag may test again the highest/lower expiry date found (configurable by category). 

=item * C<expiry_date> the expiry date taken into consideration to compute `is_expired`.

=item * C<is_pending> a flag that indicates whether the client has pending documents in this category.

=item * C<is_rejected> a flag that indicates whether the client has rejected documents in this category.

=item * C<is_outdated> an integer that indicates how many days the category has been expired

=item * C<to_be_expired> an integer that indicates in how many days a category will be expired

=item * C<to_be_outdated> an integer that indicates in how many days a category will be outdated

=back

Returns the uploaded documents for the client and its siblings, organized in a fancy structure by category.

=cut

sub _build_uploaded {
    my $self          = shift;
    my $doc_structure = sub {
        my $doc = shift;

        return {
            expiry_date => $doc->expiration_date ? $doc->expiration_date->epoch : undef,
            type        => $doc->document_type,
            format      => $doc->document_format,
            id          => $doc->document_id,
            status      => $doc->status,
        };
    };

    my $has_lifetime_valid = {};
    my %documents          = ();

    my @siblings = $self->client->user->clients(
        include_disabled   => 1,
        include_duplicated => 1,
        db_operation       => $self->client->get_db,
    );

    for my $each_sibling (@siblings) {
        next if $each_sibling->is_virtual;

        foreach my $single_document ($each_sibling->client_authentication_document) {
            my $doc_status = $single_document->status // '';
            my $origin     = $single_document->origin // 'legacy';

            # consider only uploaded documents
            next if $doc_status eq 'uploading';

            my $document_type   = $single_document->document_type;
            my $category_config = $self->get_category_config($document_type);
            next unless $category_config;

            my $category     = $category_config->{category} // 'other';
            my $category_key = $category;

            $category_key = $origin if any { $origin eq $_ } qw/onfido idv/;

            $documents{$category_key}{documents}{$single_document->file_name} = $doc_structure->($single_document);

            if (any { $category eq $_ } qw/proof_of_income proof_of_identity proof_of_address/) {
                $documents{$category_key}{'is_' . $doc_status} += 1;
            }

            if (my $ttl = $category_config->{time_to_live}) {
                if ($doc_status eq 'verified') {
                    if ($single_document->lifetime_valid || $has_lifetime_valid->{$category_key}) {
                        $documents{$category_key}->{is_outdated}        = 0;
                        $documents{$category_key}->{to_be_outdated}     = undef;
                        $documents{$category_key}->{best_issue_date}    = undef;
                        $documents{$category_key}->{best_verified_date} = undef;
                        $has_lifetime_valid->{$category_key}            = 1;
                    } else {
                        if (my $issue_date = $single_document->issue_date) {
                            my $issue_du = eval { Date::Utility->new($issue_date) };

                            if ($issue_du) {
                                $documents{$category_key}->{best_issue_date} //= $issue_du;
                                $documents{$category_key}->{best_issue_date} = $issue_du
                                    if $documents{$category_key}->{best_issue_date}->is_before($issue_du);
                            }
                        }
                        if (my $verified_date = $single_document->verified_date) {
                            my $now         = Date::Utility->new;
                            my $verified_du = eval { Date::Utility->new($verified_date) };

                            if ($verified_du) {
                                my $verification_validity = $verified_du->plus_time_interval($ttl);
                                my $days_outdated         = $now->days_between($verification_validity);
                                # we exploit the fact that days between can produce a negative number
                                # we will carry the smaller negative number (best issuance date)

                                $documents{$category_key}->{to_be_outdated} //= $days_outdated if $days_outdated <= 0;
                                $documents{$category_key}->{to_be_outdated} = $days_outdated
                                    if $days_outdated <= 0 && $days_outdated < $documents{$category_key}->{to_be_outdated};

                                $days_outdated = 0 if $days_outdated < 0;

                                $documents{$category_key}->{is_outdated} //= $days_outdated;
                                # the less days outdated the better
                                $documents{$category_key}->{is_outdated} = $days_outdated
                                    if $days_outdated < $documents{$category_key}->{is_outdated};

                                $documents{$category_key}->{best_verified_date} //= $verified_du;
                                $documents{$category_key}->{best_verified_date} = $verified_du
                                    if $documents{$category_key}->{best_verified_date}->is_before($verified_du);
                            }
                        }
                    }
                } elsif ($doc_status eq 'uploaded') {
                    $documents{$category_key}{is_pending} = 1;
                }
            }

            # The expiration analysis starts right here
            # from this point we are interested in expirable documents
            next unless ($category_config->{types}->{$document_type}->{date} // '') eq 'expiration';

            # If doc is in Needs Review and age_verification is true, then flag the category as pending
            # note that this is a `maybe pending` and can be cancelled some lines below outside the looping
            $documents{$category_key}{is_pending} = 1
                if $doc_status eq 'uploaded' && $category eq 'proof_of_identity';

            # only verified documents pass for expiration analysis
            next if $doc_status ne 'verified';

            # Populate the lifetime valid hashref per category
            $has_lifetime_valid->{$category_key}       = 1     if $single_document->lifetime_valid;
            $documents{$category_key}->{to_be_expired} = undef if $has_lifetime_valid->{$category_key};
            next if $has_lifetime_valid->{$category_key};

            # and the document should report a expiration date
            my $expires = $documents{$category_key}{documents}{$single_document->file_name}{expiry_date};
            next unless $expires;

            # We have two strategies, max and min
            # max will take into account the highest date found to validate the expiration of the category
            # min will take into account the lowest date found to validate the expiration of the category
            my $expiration_strategy = $category_config->{expiration_strategy};
            next unless ($expiration_strategy // '') =~ /\bmin|max\b/;

            my $existing_expiry_date_epoch = $documents{$category_key}{expiry_date} // $expires;
            my $expiry_date;

            $expiry_date = max($expires, $existing_expiry_date_epoch) if $expiration_strategy eq 'max';
            $expiry_date = min($expires, $existing_expiry_date_epoch) if $expiration_strategy eq 'min';

            my $now             = Date::Utility->new;
            my $expiry_datetime = Date::Utility->new($expiry_date);
            my $days_expired    = $now->days_between($expiry_datetime);

            $documents{$category_key}{expiry_date} = $expiry_date;
            $documents{$category_key}{is_expired}  = $days_expired > 0 ? 1 : 0;

            # we exploit the fact that days between can produce a negative number
            # we will carry the smaller negative number (best expiry date)

            $documents{$category_key}->{to_be_expired} //= $days_expired if $days_expired <= 0;
            $documents{$category_key}->{to_be_expired} = $days_expired
                if $days_expired <= 0 && $days_expired < $documents{$category_key}->{to_be_expired};
        }
    }

    # Remove expiration from category if lifetime valid doc was observed
    for my $category_key (keys $has_lifetime_valid->%*) {
        delete $documents{$category_key}->{expiry_date};
        delete $documents{$category_key}->{is_expired};
        $documents{$category_key}->{lifetime_valid} = 1;
    }

    for my $origin (qw/onfido idv proof_of_identity proof_of_address/) {
        if ($documents{$origin}) {
            $documents{$origin}{is_pending} //= 0;
        }
    }

    # set document status for authentication
    # status - needs_action and under_review
    my $fully_authenticated = $self->client->fully_authenticated;

    if (scalar(keys %documents) and exists $documents{proof_of_address}) {
        if (($self->client->authentication_status // '') eq 'needs_action') {
            $documents{proof_of_address}{is_rejected} = 1;
        } elsif (($self->client->authentication_status // '') eq 'under_review') {
            $documents{proof_of_address}{is_pending} = 1;
        }
    }

    # remove POI is_pending flag under fully authenticated scenario
    if (scalar(keys %documents) and exists $documents{proof_of_identity}) {
        $documents{proof_of_identity}{is_pending} = 0 if $fully_authenticated && !$documents{proof_of_identity}{is_expired};
    }
    # remove POA is_pending flag under fully authenticated scenario
    if (scalar(keys %documents) and exists $documents{proof_of_address}) {
        $documents{proof_of_address}{is_pending} = 0 if $fully_authenticated && !$documents{proof_of_address}{is_outdated};
    }

    return \%documents;
}

=head2 stash

Retrieves documents from all the siblings following the matching criteria.

It takes the following:

=over 4

=item * C<$status> - status of the documents: uploaded, verified, rejected.

=item * C<$origin> - origin of the documents: idv, onfido, bo, client, legacy.

=item * C<$types> - arrayref of document types.

=back

Returns an arrayref of documents.

=cut

sub stash {
    my ($self, $status, $origin, $types) = @_;

    my @siblings = $self->client->user->clients(
        include_disabled   => 1,
        include_duplicated => 1
    );

    my @stash;

    for my $sibling (@siblings) {
        next if $sibling->is_virtual;

        push @stash,
            $sibling->find_client_authentication_document(
            query => [
                origin        => $origin,
                status        => $status,
                document_type => $types,
            ]);
    }

    return [@stash];
}

=head2 get_category_config

Computes the category configuration of the given type of document.

Note we only care about `preferred` documents.

It takes the following argument:

=over 4

=item * C<type> A string representing the type of document

=back

Returns the configuration hashref of the given document category or undef if not found.

=cut

sub get_category_config {
    my ($self, $type) = @_;

    for my $category (values $self->categories->%*) {
        for my $category_type (keys $category->{types}->%*) {
            next unless $type eq $category_type;
            next unless $category->{types}->{$type}->{preferred};
            return $category;
        }
    }

    return undef;
}

=head2 best_expiry_date

Gets the best issue date from the given category, this is the most future expiry date from
a verified document

Returns a C<Date::Utility> or C<undef> if there is no such date.

=cut

sub best_expiry_date {
    my ($self, $type) = @_;
    my $uploaded = $self->uploaded;
    $type //= ['proof_of_identity', 'onfido'];

    $type = [$type] unless ref($type) eq 'ARRAY';

    my $best_expiry_date;

    for my $cat ($type->@*) {
        my $category = $uploaded->{$cat} // {};

        return undef if $category->{lifetime_valid};

        my $expiry_date = $category->{expiry_date};

        next unless $expiry_date;

        $best_expiry_date //= $expiry_date;

        $best_expiry_date = $expiry_date if $expiry_date > $best_expiry_date;
    }

    return Date::Utility->new($best_expiry_date) if defined $best_expiry_date;

    return undef;
}

=head2 best_issue_date

Gets the best issue date from the given category, this is the most future issue data from
a verified document

Returns a C<Date::Utility> or C<undef> if there is no such date.

=cut

sub best_issue_date {
    my ($self, $type) = @_;
    my $uploaded = $self->uploaded;
    $type //= 'proof_of_address';

    my $category = $uploaded->{$type} // {};

    my $best_issue_date = $category->{best_issue_date};

    return undef unless $best_issue_date;

    return Date::Utility->new($best_issue_date);
}

=head2 best_poa_date

Gets the best poa date from the given document and date category, this is the most future date data from a verified document

Date category may be best_issue_date or best_verified_date

Returns a C<Date::Utility> or C<undef> if there is no such date or no such date category.

=cut

sub best_poa_date {
    my ($self, $doc_category, $date_category) = @_;
    my $uploaded = $self->uploaded;
    $doc_category //= 'proof_of_address';

    my $category = $uploaded->{$doc_category} // {};

    my $best_date = $category->{$date_category};

    return undef unless $best_date;

    return Date::Utility->new($best_date);
}

=head2 outdated

Determines wether the client has outdated documents in the given category.

Driven by `time_to_live` field. If not defined the category does not apply.

Ignores documents without issuance date.

Returns an integer for the number of days in the outdated status.

C<0> if not outdated.

=cut

sub outdated {
    my ($self, $type) = @_;
    my $uploaded = $self->uploaded;
    $type //= 'proof_of_address';

    my $category = $uploaded->{$type} // {};

    return $category->{is_outdated} // 0;
}

=head2 to_be_outdated

Returns the number of days a category will get outdated.

It takes the following paremeters

=over 4

=item * C<$category> - the category, by default `proof_of_address`

=back

Returns an integer or C<undef> if the catgory won't expire.

=cut

sub to_be_outdated {
    my ($self, $category) = @_;
    my $uploaded = $self->uploaded;
    $category //= 'proof_of_address';

    my $data = $uploaded->{$category} // {};

    # this is a negative number
    my $days = $data->{to_be_outdated};

    return abs($days) if defined $days;

    return undef;
}

=head2 to_be_expired

Returns the number of days a category will get outdated.

It takes the following paremeters

=over 4

=item * C<$category> - the category, by default `proof_of_identity`

=back

Returns an integer or C<undef> if the category won't expire.

=cut

sub to_be_expired {
    my ($self, $categories) = @_;

    $categories //= ['onfido', 'proof_of_identity'];

    $categories = [$categories] unless ref($categories) eq 'ARRAY';

    my $uploaded = $self->uploaded;

    my $best_expiration = undef;

    for my $cat ($categories->@*) {
        my $data = $uploaded->{$cat} // {};

        return undef if defined $data->{lifetime_valid};

        # this is a negative number
        my $days = $data->{to_be_expired};

        $days = abs($days) if defined $days;

        $best_expiration = $days if defined $days && ($best_expiration // $days) <= $days;
    }

    return $best_expiration;
}

=head2 expiration_look_ahead

Given a number of days, this function determines if the client's document will expire on that timeframe.

Takes the following:

=over 4

=item * C<$days> - number of days to look ahead

=item * C<$expired_categories> - arrayref of categories to check for expiration, defaults to poi+onfido

=item * C<$outdated_category> - category to look for outdated documents, defaults to poa

=back

Returns a boolean value

=cut

sub expiration_look_ahead {
    my ($self, $days, $expired_categories, $outdated_category) = @_;

    $expired_categories //= ['proof_of_identity', 'onfido'];
    $outdated_category  //= 'proof_of_address';

    my $expiring_within = $self->to_be_expired($expired_categories) // $days + 1;    # just a trick to bypass the if below

    return 1 if $expiring_within <= $days;

    my $outdated_within = $self->to_be_outdated($outdated_category) // $days + 1;    # just a trick to bypass the if below

    return 1 if $outdated_within <= $days;

    return 0;
}

=head2 expired

Computes the expired flag from existing client POI documents.

Note the special case when we compute 0 for empty POI documents

It may take the following argument:

=over 4

=item * enforce, (optional) activate this flag to always check for expired docs no matter the context

=item * categories, (optional) defaults to [onfido, proof_of_identity]

=back

Clients needs at least 1 category to pass to not be considered expired.

It returns the computed flag.

=cut

sub expired {
    my ($self, $enforce, $categories) = @_;

    $categories //= ['onfido', 'proof_of_identity'];

    $categories = [$categories] if ref($categories) ne 'ARRAY';

    my $has_expirable_docs;

    for my $cat ($categories->@*) {
        my $category = $self->uploaded->{$cat} // {};

        next unless defined $category->{documents};

        return 0 if defined $category->{lifetime_valid};

        next unless defined $category->{is_expired};

        next unless $self->has_expirable_docs($category);

        $has_expirable_docs = 1;

        return 0 if $self->valid($cat, $enforce);
    }

    return 1 if $has_expirable_docs;

    return 0;
}

=head2 has_expirable_docs

Filters out the non-expirable docs based on the document_type_categories.yml,
returning 1 if the client has expirable docs, o.w. returns 0.

It takes the following parameter as a hashref:

=over 4

=item * category, documents corresponding to said category

=back

It returns the computed flag.

=cut

sub has_expirable_docs {
    my ($self, $category) = @_;

    my $documents = $category->{documents};

    my %types = map { $_ => 1 } $self->expirable_types->@*;

    my $expirable_documents = {
        map  { $_ => $documents->{$_} }
        grep { exists $types{$documents->{$_}->{type}} } keys %$documents
    };
    return %$expirable_documents ? 1 : 0;
}

=head2 valid

Computes the valid flag from existing client documents.

Note the special case when we compute 0 for empty documents in the specified category.

It may take the following argument:

=over 4

=item * type, (optional) the type of document we are checking, will check them all if not specified

=item * enforce, (optional) activate this flag to always check for expired docs no matter the context

=back


It returns the computed flag.

=cut

sub valid {
    my ($self, $type, $enforce) = @_;

    my $is_poi_expiration_check_required = $enforce // $self->client->is_poi_expiration_check_required();

    # If type is specified disregard the other types
    my @types = grep { exists $self->uploaded->{$_}{documents} } $type ? ($type) : (keys $self->uploaded->%*);

    # no documents
    return 0 unless @types;

    # small optimization
    return 1 unless $is_poi_expiration_check_required;

    # Note `is_expired` is calculated from the max expiration timestamp found for POI
    # Other type of documents take the min expiration timestamp found
    return 0 if any { $self->uploaded->{$_}{is_expired} } @types;

    return 1;
}

=head2 poa_types

Lazily computes the list of proof of address document types.

=cut

has poa_types => (
    is      => 'lazy',
    clearer => '_clear_poa_types',
);

=head2 _build_poa_types

Get an arrayref of POA doctypes.

=cut

sub _build_poa_types {
    my $self = shift;
    return BOM::User::Client::AuthenticationDocuments::Config::poa_types();
}

=head2 poi_types

Lazily computes the list of proof of identity document types.

=cut

has poi_types => (
    is      => 'lazy',
    clearer => '_clear_poi_types',
);

=head2 _build_poi_types

Get an arrayref of POI doctypes.

=cut

sub _build_poi_types {
    my $self = shift;
    return [keys $self->categories->{POI}->{types}->%*];
}

=head2 dateless_types

Lazily computes the list of date less document types (date eq `none`)

=cut

has dateless_types => (
    is      => 'lazy',
    clearer => '_clear_dateless_types',
);

=head2 _build_dateless_types

Computes the list of document type that does not carry a date of any kind.

Returns an arrayref of such document types.

=cut

sub _build_dateless_types {
    my $self = shift;
    my $list = [];

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            my $document_type_date_conf = $category->{types}->{$document_type}->{date} // '';
            push $list->@*, $document_type if $document_type_date_conf eq 'none';
        }
    }

    return $list;
}

=head2 expirable_types

Lazily computes the list of expirable document types (date eq `expiration`)

=cut

has expirable_types => (
    is      => 'lazy',
    clearer => '_clear_expirable_types',
);

=head2 _build_expirable_types

Computes the list of document type that should have an expiration date.

Returns an arrayref of such document types.

=cut

sub _build_expirable_types {
    my $self = shift;
    my $list = [];

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            my $document_type_date_conf = $category->{types}->{$document_type}->{date} // '';
            push $list->@*, $document_type if $document_type_date_conf eq 'expiration';
        }
    }

    return $list;
}

=head2 issuance_types

Lazily computes the list of issuance document types (date eq `issuance`)

=cut

has issuance_types => (
    is      => 'lazy',
    clearer => '_clear_issuance_types',
);

=head2 _build_issuance_types

Computes the list of document type that should have an issuance date.

Returns an arrayref of such document types.

=cut

sub _build_issuance_types {
    my $self = shift;
    my $list = [];

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            my $document_type_date_conf = $category->{types}->{$document_type}->{date} // '';
            push $list->@*, $document_type if $document_type_date_conf eq 'issuance';
        }
    }

    return $list;
}

=head2 preferred_types

Lazily computes the list of preferred document types

=cut

has preferred_types => (
    is      => 'lazy',
    clearer => '_clear_preferred_types',
);

=head2 _build_preferred_types

Computes the list of document type that are taken into consideration for authentication purposes.

Returns an arrayref of such document types.

=cut

sub _build_preferred_types {
    my $self = shift;
    my $list = [];

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            my $is_preferred = $category->{types}->{$document_type}->{preferred};
            push $list->@*, $document_type if $is_preferred;
        }
    }

    return $list;
}

=head2 maybe_lifetime_types

Lazily computes the list of documents that could be lifetime valid.

=cut

has maybe_lifetime_types => (
    is      => 'lazy',
    clearer => '_clear_maybe_lifetime_types',
);

=head2 _build_maybe_lifetime_types

Computes the list of document type that could be lifetime valid.

These document types should be: expirable + preferred

Returns an arrayref.

=cut

sub _build_maybe_lifetime_types {
    my $self      = shift;
    my @preferred = $self->preferred_types->@*;
    my @expirable = $self->expirable_types->@*;
    return [intersect(@preferred, @expirable)];
}

=head2 sided_types

Types that have one or more defined sides.

=cut

has sided_types => (
    is      => 'lazy',
    clearer => '_clear_sided_types',
);

=head2 _build_sided_types

Computes a hashref such that its keys are defined sides and its values are
the set of all document types containing the defined side.

Returns a hashref.

=cut

sub _build_sided_types {
    my $self        = shift;
    my $sided_types = {};

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            my $sides = [keys $category->{types}->{$document_type}->{sides}->%*];

            for my $side ($sides->@*) {
                push $sided_types->{$side}->@*, $document_type;
            }
        }
    }

    return $sided_types;
}

=head2 sides

A collection of defined sides.

=cut

has sides => (
    is      => 'lazy',
    clearer => '_clear_sides',
);

=head2 _build_sides

Computes a hashref such that its keys are defined sides and its values are
the display name of the defined side.

Returns a hashref.

=cut

sub _build_sides {
    my $self  = shift;
    my $sides = {};

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            $sides = {$category->{types}->{$document_type}->{sides}->%*, $sides->%*,};
        }
    }

    return $sides;
}

=head2 numberless

A collection of document types that are numberless (document id not required).

=cut

has numberless => (
    is      => 'lazy',
    clearer => '_clear_numberless',
);

=head2 _build_numberless

Computes a list of numberless document types.

Returns an arraref.

=cut

sub _build_numberless {
    my $self       = shift;
    my $numberless = [];

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            push $numberless->@*, $document_type if $category->{types}->{$document_type}->{numberless};
        }
    }

    return $numberless;
}

=head2 get_authentication_definition

a method to give back the authentication_definition

=cut

sub get_authentication_definition {
    my ($class, $status) = @_;
    my %AUTHENTICATION_DEFINITION = (
        'CLEAR_ALL'    => 'Not authenticated',
        'ID_DOCUMENT'  => 'Authenticated with scans',
        'ID_NOTARIZED' => 'Authenticated with Notarized docs',
        'ID_PO_BOX'    => 'Authenticated with PO BOX verified',
        'ID_ONLINE'    => 'Authenticated with online verification',
        'NEEDS_ACTION' => 'Needs Action',
        'IDV'          => 'Authenticated with IDV + POA',
        'IDV_PHOTO'    => 'Authenticated with IDV + Photo',
    );
    return $AUTHENTICATION_DEFINITION{$status};
}

=head2 provider_types

A collection of document types that are valid to upload to different providers supported.

=cut

has provider_types => (
    is      => 'lazy',
    clearer => '_clear_provider_types',
);

=head2 _build_provider_types

Computes a nested hashref of hashref of valid document types.

The outer mapping corresponds to each provider.

The inner mapping corresponds to our document type definition to the provider equivalent type.

Returns a hashref of hashref.

=cut

sub _build_provider_types {
    my $self  = shift;
    my $types = {};

    for my $category (values $self->categories->%*) {
        for my $document_type (keys $category->{types}->%*) {
            if (my $providers = $category->{types}->{$document_type}->{providers}) {
                for my $provider (keys $providers->%*) {
                    $types->{$provider}->{$document_type} = $providers->{$provider};
                }
            }
        }
    }

    return $types;
}

=head2 verified

Determines whether the documents are in a verified status.

It returns a boolean value.

=cut

sub verified {
    my ($self) = @_;

    my $poi = $self->uploaded->{proof_of_identity} || return 0;

    return 0 if $poi->{is_expired};

    return $poi->{is_verified};
}

=head2 pending

Determines whether the documents are in a pending status.
It returns a boolean value.

=cut

sub pending {
    my ($self) = @_;

    my $poi = $self->uploaded->{proof_of_identity} || return 0;

    return $poi->{is_pending};
}

=head2 is_poa_verified

Flag that determines whether the client has at least 1 verified PoA document.

=cut

has is_poa_verified => (
    is      => 'lazy',
    clearer => '_clear_is_poa_verified',
);

=head2 _build_is_poa_verified

Computes the PoA verification status of the user.

It returns C<1> if at least one of the PoA documents is verified.

Otherwise it will return C<0>.

=cut

sub _build_is_poa_verified {
    my ($self) = @_;

    return 0 if $self->outdated('proof_of_address');

    for my $doc (values $self->uploaded->{proof_of_address}->{documents}->%*) {
        return 1 if $doc->{status} eq 'verified';
    }

    return 0;
}

=head2 pow_types

Lazily computes the list of POW (proof of income/wealth) document types.

=cut

has pow_types => (
    is      => 'lazy',
    clearer => '_clear_pow_types',
);

=head2 _build_pow_types

Get an arrayref of POW (proof of income/wealth) doctypes.

=cut

sub _build_pow_types {
    my $self = shift;
    my $pow  = [];

    for my $category (values $self->categories->%*) {
        if ($category->{category} && $category->{category} eq 'proof_of_income') {
            for my $document_type (keys $category->{types}->%*) {
                push $pow->@*, $document_type;
            }
        }
    }

    return $pow;
}

=head2 poa_address_mismatch

Getter/setter of the POA address mismatch.

It takes the following arguments as a hashref:

=over 4

=item * C<expected_address>: the address the client must complete in order to get fully authenticated

=item * C<staff>: name of the staff who is setting the status (optional)

=item * C<reason>: reason of the status (optional)

=back

Return the current expected address or C<undef> if none.

=cut

sub poa_address_mismatch {
    my ($self, $args) = @_;
    my $redis = BOM::Config::Redis::redis_replicated_write();
    my ($expected_address, $staff, $reason) = @{$args}{qw/expected_address staff reason/};

    if ($expected_address) {
        $self->client->status->upsert('poa_address_mismatch', $staff // 'system', $reason // 'Proof of Address mismatch detected');
        $redis->set(POA_ADDRESS_MISMATCH_KEY . $self->client->binary_user_id, $expected_address, 'EX', POA_ADDRES_MISMATCH_TTL);
    }

    return $redis->get(POA_ADDRESS_MISMATCH_KEY . $self->client->binary_user_id);
}

=head2 is_poa_address_fixed

This sub checks to see if the newly inserted address matches the expected address saved in redis

=over 4

=back

Returns Boolean.

=cut

sub is_poa_address_fixed {
    my ($self) = @_;

    my $redis = BOM::Config::Redis::redis_replicated_write();

    my $expected_address = $redis->get(POA_ADDRESS_MISMATCH_KEY . $self->client->binary_user_id);

    return 0 unless $expected_address;

    my $curr_address = $self->client->address_1;

    # Expected
    # Remove non alphanumeric
    $expected_address =~ s/[^a-zA-Z0-9 ]//g;

    # Current
    # Remove non alphanumeric
    $curr_address =~ s/[^a-zA-Z0-9 ]//g;

    my $address_similarity_ratio = check_words_similarity($curr_address, $expected_address);

    if ($address_similarity_ratio > 0.85) {
        return 1;
    }

    return 0;

}

=head2 poa_address_fix

This sub clears the poa address mismatch from the client and also set it as fully authenticated.

Only takes effect under the C<poa_address_mismatch> status.

It takes the following arguments as hashref:

=over 4

=item * C<staff>: name of the staff who is resolving the POA mismatch

=back

Returns C<undef>.

=cut

sub poa_address_fix {
    my ($self, $args) = @_;

    if ($self->client->status->poa_address_mismatch) {
        my $staff = $args->{staff};

        for my $doc ($self->client->find_client_authentication_document(query => [address_mismatch => 1])->@*) {
            $doc->address_mismatch(0);
            $doc->status('verified');
            $doc->save;
        }

        $self->client->status->clear_poa_address_mismatch;

        my $redis = BOM::Config::Redis::redis_replicated_write();

        $redis->del(POA_ADDRESS_MISMATCH_KEY . $self->client->binary_user_id);

        $self->client->status->upsert('address_verified', $staff // 'system', 'Address has been verified after address mismatch has been corrected');

        if ($self->client->status->age_verification) {
            $self->client->set_authentication_and_status('ID_DOCUMENT', $staff // 'system');
        }
    }

    return undef;
}

=head2 poa_address_mismatch_clear

This sub clears the poa address mismatch from BO in case of mistake.

Only takes effect under the C<poa_address_mismatch> status.

=over 4

=back

Returns C<undef>.

=cut

sub poa_address_mismatch_clear {
    my $self = shift;

    if ($self->client->status->poa_address_mismatch) {

        $self->client->status->clear_poa_address_mismatch;

        my $redis = BOM::Config::Redis::redis_replicated_write();

        $redis->del(POA_ADDRESS_MISMATCH_KEY . $self->client->binary_user_id);
    }

    return undef;
}

=head2 check_words_similarity

This sub determines whether each word of C<$expected>
is in C<$actual> value (word by word comparison).

It takes the following arguments:

=over 4

=item * C<$actual> - the actual words.

=item * C<$expected> - the expected words.

=back

Returns ratio of found words.

=cut

sub check_words_similarity {
    my ($actual, $expected) = @_;

    my @actuals      = split ' ', lc $actual;
    my @expectations = split ' ', lc $expected;

    return intersect(@actuals, @expectations) / @expectations;
}

=head2 latest

Gets the latest POI document uploaded (not in the uploading status).

=cut

has latest => (
    is      => 'lazy',
    clearer => '_clear_latest',
);

=head2 _build_latest

Retrieves the latest uploaded document.

Returns hashref or C<undef> if there is no such a document.

=cut

sub _build_latest {
    my ($self) = @_;

    my ($latest) = $self->client->db->dbic->run(
        fixup => sub {
            return $_->selectall_array(
                "SELECT * FROM betonmarkets.get_latest_document(?, ?)",
                {Slice => {}},
                $self->client->binary_user_id,
                $self->poi_types,
            );
        });

    return undef if !$latest || !$latest->{id};

    return $latest;
}

=head2 get_poinc_count

Returns the number of proof of income documents a client have 

=over 4

=item * C<get_poinc_count> - client instance

=item * C<docs> - client documents

=back

=cut

sub get_poinc_count {
    my ($self, $docs) = @_;

    return 0 unless $docs;
    my @poinc_doctypes = $self->pow_types->@*;
    my $poinc_count;
    foreach my $doc (@$docs) {
        my $doc_type = $doc->{'document_type'};
        if (grep({ /^$doc_type$/ } @poinc_doctypes)) {
            $poinc_count++;
        }
    }
    return $poinc_count;
}

=head2 poi_expiration_look_ahead

Computes a flag that determines whether the POI is expiring within the established
timeframe the client should be able to re-upload it.

=cut

sub poi_expiration_look_ahead {
    my ($self) = @_;

    return 0 unless $self->client->user->has_mt5_regulated_account(use_mt5_conf => 1);

    my $to_be_expired_at = $self->to_be_expired() // return undef;

    return 1 if $to_be_expired_at <= DOCUMENT_EXPIRING_SOON_DAYS_TO_LOOK_AHEAD;

    return 0;
}

=head2 poa_outdated_look_ahead

Computes a flag that determines whether the POA is getting outdated within the established
timeframe the client should be able to re-upload it.

=cut

sub poa_outdated_look_ahead {
    my ($self) = @_;

    return 0 unless $self->client->user->has_mt5_regulated_account(use_mt5_conf => 1);

    my $to_be_outdated_at = $self->to_be_outdated() // return 0;

    return 1 if $to_be_outdated_at <= DOCUMENT_EXPIRING_SOON_DAYS_TO_LOOK_AHEAD;

    return 0;
}

=head2 is_upload_available

Checks if Manual Upload is available for the client

It takes the following param:

=over 4

=item * L<BOM::User::Client> the client

=back

Returns,
    1 if Manual Upload is available for the client
    0 if Manual Upload is not available for the client

Manual Upload is available for the client if:
    - has not exceeded the maximum allowed uploads per day 

=cut

sub is_upload_available {
    my ($self) = @_;

    my $redis        = BOM::Config::Redis::redis_replicated_write();
    my $key          = MAX_UPLOADS_KEY . $self->client->binary_user_id;
    my $upload_tries = $redis->get($key) // 0;
    my $is_available = $upload_tries < MAX_UPLOAD_TRIES_PER_DAY;

    return $is_available;
}

=head2 owned

Determines whether the client owns the specified document, it takes:

=over 4

=item * C<type> - type of the document

=item * C<numbers> - numbers of the document

=item * C<country> - country of the document

=back

Returns a boolean scalar.

=cut

sub owned {
    my ($self, $type, $numbers, $country) = @_;

    return $self->client->binary_user_id == ($self->client->user->documents->poi_ownership($type, $numbers, $country) // 0);
}

=head2 pending_poi_bundle

Obtains a bundle of pending POI documents. A proper bundle will contain a selfie picture and also both sides (both and back),
if the document type requires it, some documents type are single sided like passports, for those one picture is enough.

It takes the following params as hashref:

=over 4

=item C<onfido_country> - (optional) check for Onfido supported issuing countries only

=back

Returns a stash of documents as hashref, containing:

=over 4

=item C<selfie> - id of the selfie

=item C<documents> - arrayref of document ids

=back

Or C<undef> if there is no complete bundle.

=cut

sub pending_poi_bundle {
    my ($self, $args) = @_;
    my $client         = $self->client;
    my $onfido_country = $args->{onfido_country};

    # this sorting will ensure (not 100% though but pretty close) that the documents being processed are related to each other in sequence
    my $stash = [
        sort { $b->id <=> $a->id }
            $client->documents->stash('uploaded', 'client',
            ['national_identity_card', 'identification_number_document', 'driving_licence', 'passport', 'selfie_with_id'])->@*
    ];

    # having the stash of POI potential documents
    # we need to find a valid cluster of documents:
    #  - passport + selfie_with_id
    #  - driving_licence (front and back) + selfie_with_id
    #  - national_identity_card (front and back) + selfie_with_id
    #  - identification_number_document (front and back) + selfie_with_id

    my $stack = {};
    my $selfie;

    # extract the selfie (easy)
    # and the candidate documents (hard)

    for my $document ($stash->@*) {
        next unless !$onfido_country || BOM::Config::Onfido::is_country_supported($document->issuing_country);

        my $type = $document->document_type;

        if ($type eq 'selfie_with_id') {
            $selfie = $document unless $selfie;
            next;
        }

        my $side = $document->file_name =~ /_front\./ ? 'front' : 'back';

        # index by document id (numbers) + country + type, so we stack related documents

        my $index = join '-', $document->document_id, $document->issuing_country, $type;

        $stack->{$index} //= {};

        # index again (2nd dimension) by its side (front/back), as some document types are 2 sided

        $stack->{$index}->{$side} = $document unless $stack->{$index}->{$side};
    }

    return undef unless $selfie;

    # observe the 2 dimensional stack built,
    # for passport we need 1 document
    # the rest of the documents types would require 2
    # if some stack matches the criteria we just found our candidates, bravo!
    my $documents;
    my $highest;

    for (keys $stack->%*) {
        my $docs = $stack->{$_};

        my ($first, $second) = sort { $b->id <=> $a->id } values $docs->%*;

        my $type = $first->document_type;

        if ($type eq 'passport') {
            $documents = [$first->id, $first] if $first && (!defined $highest || $first->id > $highest);
        } else {
            $documents = [$first->id, $first, $second] if $first && $second && (!defined $highest || $first->id > $highest);
        }

        $highest = $documents->[0] if $documents;    # carry only the highest id found
    }

    return undef unless $documents;

    # now get the documents without the first element (highest id)
    my @documents = $documents->@*;
    shift @documents;

    return {
        selfie    => $selfie,
        documents => [@documents],
    };
}

1;

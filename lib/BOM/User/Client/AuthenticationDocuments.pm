package BOM::User::Client::AuthenticationDocuments;

use strict;
use warnings;
use Moo;

use List::Util qw(first any min max);
use Array::Utils qw(intersect);
use Path::Tiny;
use YAML::XS;
use Dir::Self;

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

    my $path                     = Path::Tiny::path(__DIR__)->parent(4)->child('share', 'document_type_categories.yml');
    my $document_type_categories = YAML::XS::LoadFile($path);
    return $document_type_categories;
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

Each key corresponds to a category of documents (e.g. proof_of_identity, proof_of_address) 
and it may contain:

=over 4

=item * C<documents> a hashref containing each individual document by file name.

=item * C<is_expired> a flag that indicates whether the client has expired documents, note this flag may test again the highest/lower expiry date found (configurable by category). 

=item * C<expiry_date> the expiry date taken into consideration to compute `is_expired`.

=item * C<is_pending> a flag that indicates whether the client has pending documents in this category.

=item * C<is_rejected> a flag that indicates whether the client has rejected documents in this category.

=back

Returns the uploaded documents for the client and its siblings, organized in a fancy structure by category.

=cut

sub _build_uploaded {
    my $self = shift;

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
        include_duplicated => 1
    );

    for my $each_sibling (@siblings) {
        next if $each_sibling->is_virtual;

        foreach my $single_document ($each_sibling->client_authentication_document) {
            my $doc_status = $single_document->status // '';

            # consider only uploaded documents
            next if $doc_status eq 'uploading';

            my $document_type   = $single_document->document_type;
            my $category_config = $self->get_category_config($document_type);
            next unless $category_config;

            my $category = $category_config->{category} // 'other';
            $documents{$category}{documents}{$single_document->file_name} = $doc_structure->($single_document);

            # The expiration analysis starts right here
            # from this point we are interested in expirable documents
            next unless ($category_config->{types}->{$document_type}->{date} // '') eq 'expiration';

            # If doc is in Needs Review and age_verification is true, then flag the category as pending
            # note that this is a `maybe pending` and can be cancelled some lines below outside the looping
            $documents{proof_of_identity}{is_pending} = 1
                if $doc_status eq 'uploaded' && $category eq 'proof_of_identity' && $self->client->status->age_verification;

            # only verified documents pass for expiration analysis
            next if $doc_status ne 'verified';

            # Populate the lifetime valid hashref per category
            $has_lifetime_valid->{$category} = 1 if $single_document->lifetime_valid;
            next                                 if $has_lifetime_valid->{$category};

            # and the document should report a expiration date
            my $expires = $documents{$category}{documents}{$single_document->file_name}{expiry_date};
            next unless $expires;

            # Dont propagate expiry if is age verified by Experian
            next if $self->client->status->is_experian_validated and $category eq 'proof_of_identity';

            # We have two strategies, max and min
            # max will take into account the highest date found to validate the expiration of the category
            # min will take into account the lowest date found to validate the expiration of the category
            my $expiration_strategy = $category_config->{expiration_strategy};
            next unless ($expiration_strategy // '') =~ /\bmin|max\b/;

            my $existing_expiry_date_epoch = $documents{$category}{expiry_date} // $expires;
            my $expiry_date;

            $expiry_date = max($expires, $existing_expiry_date_epoch) if $expiration_strategy eq 'max';
            $expiry_date = min($expires, $existing_expiry_date_epoch) if $expiration_strategy eq 'min';

            $documents{$category}{expiry_date} = $expiry_date;
            $documents{$category}{is_expired}  = Date::Utility->new->epoch > $expiry_date ? 1 : 0;
        }
    }

    # Remove expiration from category if lifetime valid doc was observed
    for my $category (keys $has_lifetime_valid->%*) {
        delete $documents{$category}->{expiry_date};
        delete $documents{$category}->{is_expired};
    }

    if (scalar(keys %documents) and exists $documents{proof_of_identity}) {
        $documents{proof_of_identity}{is_pending} = 1 unless $self->client->status->age_verification;
    }

    # Cancel the is_pending for an age_verified account that does not have verified expired docs
    if ($documents{proof_of_identity}{is_pending}) {
        $documents{proof_of_identity}{is_pending} = 0 if $self->client->status->age_verification and not $documents{proof_of_identity}{is_expired};
    }

    # set document status for authentication
    # status - needs_action and under_review

    if (scalar(keys %documents) and exists $documents{proof_of_address}) {
        if (($self->client->authentication_status // '') eq 'needs_action') {
            $documents{proof_of_address}{is_rejected} = 1;
        } elsif (not $self->client->fully_authenticated or $self->client->ignore_address_verification) {
            $documents{proof_of_address}{is_pending} = 1;
        }
    }

    return \%documents;
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

=head2 expired

Computes the expired flag from existing client POI documents.

Note the special case when we compute 0 for empty POI documents

It may take the following argument:

=over 4

=item * enforce, (optional) activate this flag to always check for expired docs no matter the context

=back

It returns the computed flag.

=cut

sub expired {
    my ($self, $enforce) = @_;

    # no POI documents
    return 0 unless defined $self->uploaded->{proof_of_identity}{documents};
    return $self->valid('proof_of_identity', $enforce) ? 0 : 1;
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

    my $is_document_expiry_check_required = $enforce // $self->client->is_document_expiry_check_required();

    # If type is specified disregard the other types
    my @types = grep { exists $self->uploaded->{$_}{documents} } $type ? ($type) : (keys $self->uploaded->%*);

    # no documents
    return 0 unless @types;

    # Note `is_expired` is calculated from the max expiration timestamp found for POI
    # Other type of documents take the min expiration timestamp found
    return 0 if any { $self->uploaded->{$_}{is_expired} and $is_document_expiry_check_required } @types;

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
    return [keys $self->categories->{POA}->{types}->%*];
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

1;

package BOM::Platform::MyAffiliates::ExposureManager;

=head1 NAME

BOM::Platform::MyAffiliates::ExposureManager

=head1 DESCRIPTION

Manages a group of exposures; has methods that allow exposures to be added,
modified etc.

=head1 SYNOPSIS

    my $manager = BOM::Platform::MyAffiliates::ExposureManager->new(client => $client);

=cut

use strict;
use warnings;
use Moose;
use Carp;
use List::Util qw( first );
use DateTime;
use BOM::Platform::MyAffiliates;
use BOM::Platform::Client;

=head1 ATTRIBUTES

=head2 client

=cut

has 'client' => (
    is       => 'ro',
    isa      => 'BOM::Platform::Client',
    required => 1,
);

#
# This holds all exposures that are already held in our database.
#
has '_exposures_from_db' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__exposures_from_db {
    my $self = shift;

    my $exposures = $self->client->find_client_affiliate_exposure;    # Rose.  find_ ensures a re-read.

    my %id_to_exposure = map { $_->id => $_ } @$exposures;

    return \%id_to_exposure;
}

#
# If any exposures initially from database are updated on the object,
# they are held here until they are saved back to DB.
#
has '_exposures_updated' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);
sub _build__exposures_updated { return {}; }

#
# New exposures added to the Client are stored here until saved to DB.
#
has '_exposures_added' => (
    is         => 'rw',
    isa        => 'ArrayRef',
    lazy_build => 1,
);
sub _build__exposures_added { return []; }

=head2 creative_affiliate_id

This gives the id of the affiliate that should be credited for creative
exposure, if such an id exists.

=cut

has 'creative_affiliate_id' => (
    is         => 'rw',
    isa        => 'Maybe[Num]',
    lazy_build => 1,
);

sub _build_creative_affiliate_id {
    my $self = shift;

    my ($creative_affiliate_id, $creative_media_id, $record_date) = $self->_get_creative_affiliate_info;

    $self->creative_media_id($creative_media_id);
    $self->creative_record_date($record_date);

    return $creative_affiliate_id;
}

=head2 creative_media_id

The id of the media that was shown in the creative exposure, for which
the affiliate given in creative_affiliate_id will be credited for.

=cut

has 'creative_media_id' => (
    is         => 'rw',
    isa        => 'Maybe[Num]',
    lazy_build => 1,
);

sub _build_creative_media_id {
    my $self = shift;

    my ($creative_affiliate_id, $creative_media_id, $record_date) = $self->_get_creative_affiliate_info;

    $self->creative_affiliate_id($creative_affiliate_id);
    $self->creative_record_date($record_date);

    return $creative_media_id;
}

=head2 creative_record_date

The date that the creative exposure took place. This date is the same as
the date when the actual qualifying exposure involving creative media
took place.

=cut

has 'creative_record_date' => (
    is         => 'rw',
    isa        => 'Maybe[DateTime]',
    lazy_build => 1,
);

sub _build_creative_record_date {
    my $self = shift;

    my ($creative_affiliate_id, $creative_media_id, $record_date) = $self->_get_creative_affiliate_info;

    $self->creative_affiliate_id($creative_affiliate_id);
    $self->creative_media_id($creative_media_id);

    return $record_date;
}

#
# Since creative_affiliate_id and creative_media_id are retrieved from the
# same source, it makes sense to set them at the same time. This method
# retrievs both of them from the response of an appropriate API call.
#
sub _get_creative_affiliate_info {
    my $self = shift;

    my @exposures = $self->_get_exposures;
    my $creative_affiliate_id;
    my $creative_media_id;
    my $creative_exposure_record_date;

    EXPOSURE:
    foreach my $exposure (@exposures) {
        my $token = $exposure->myaffiliates_token;

        # only consider exposures prior to account funding
        my $first_funded_date = $self->client->first_funded_date;

        if ($first_funded_date and $first_funded_date->epoch < $exposure->exposure_record_date->epoch) {
            next EXPOSURE;
        }

        my $token_info = $self->_decode_token_api_response->{$token};

        if ($creative_affiliate_id = _get_creative_affiliate_id_from_token_info($token_info)) {
            $creative_media_id             = $token_info->{'MEDIA_ID'};
            $creative_exposure_record_date = $exposure->exposure_record_date;
            last EXPOSURE;
        }
    }

    return ($creative_affiliate_id, $creative_media_id, $creative_exposure_record_date);
}

#
# Retrieves creative_affiliate_id from API response. Makes sure the id
# is taken from the correct meta key, and that it is an integer.
#
sub _get_creative_affiliate_id_from_token_info {
    my $token_info = shift;
    my $creative_affiliate_id;

    my $metadata_ref = $token_info->{'MEDIA'}->{'METADATA'}->{'META'};

    my @meta_data;
    if (ref $metadata_ref eq 'ARRAY') {
        @meta_data = @{$metadata_ref};
    } elsif (ref $metadata_ref eq 'HASH') {
        push @meta_data, $metadata_ref;
    }

    META_TAG:
    foreach my $meta_tag (@meta_data) {
        my $meta_key = $meta_tag->{'KEY'} || '';

        # key/value pairs that are not defined on the first line of the metadata
        # textarea in the MyAffiliates backend have leading new line characters!
        $meta_key =~ s/^[\n\r]+//;

        if ($meta_key eq 'creative_affiliate_id' and $meta_tag->{'VALUE'} =~ /^(\d+)$/) {
            $creative_affiliate_id = $1;
            last META_TAG;
        }
    }

    return $creative_affiliate_id;
}

#
# A container for the MyAffilies "Decode Tokens" API response. Appropriate
# to store it in an object attribute as it is examined a few times after
# it is initially received.
#
has '_decode_token_api_response' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__decode_token_api_response {
    my $self = shift;

    my %token_to_full_token_info;

    my @all_exposures = $self->_get_exposures;

    if (@all_exposures) {
        # The API lookup is done to find the creative affiliate id. If we have
        # already marked an exposure as "pay for", we know that the creative
        # affiliate id for the client is the affiliate id in the token of that
        # exposure. So, we only look up that token.
        #
        my @exposures_to_look_up = grep { $_->pay_for_exposure } @all_exposures;
        if (not @exposures_to_look_up) {
            @exposures_to_look_up = @all_exposures;
        }

        if (@exposures_to_look_up) {
            my $api      = BOM::Platform::MyAffiliates->new;
            my @tokens   = map { $_->myaffiliates_token } @exposures_to_look_up;
            my $response = $api->decode_token(@tokens);

            my $token_info_ref = (ref $response->{'TOKEN'} eq 'HASH') ? [$response->{'TOKEN'}] : $response->{'TOKEN'};

            %token_to_full_token_info = map { $_->{'PREFIX'} => $_ } @{$token_info_ref};
        }
    }

    return \%token_to_full_token_info;
}

sub BUILDARGS {
    my ($class, %args) = @_;

    if (not $args{'client'} or not UNIVERSAL::isa($args{'client'}, 'BOM::Platform::Client')) {
        croak 'If not specifying client, period start/end must be given.';
    }

    return \%args;
}

=head2 add_exposure

To add a new exposure to the object, use this method.
Accepts an instance of BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure

=cut

sub add_exposure {
    my ($self, $exposure) = @_;

    if ($exposure->signup_override
        and first { $_->signup_override && $exposure->myaffiliates_token eq $_->myaffiliates_token } $self->_get_exposures)
    {
        croak $self->client->loginid . ' already has signup_override token ' . $exposure->myaffiliates_token . ' set.';
    }

    if ($exposure->pay_for_exposure
        and first { $_->pay_for_exposure && $exposure->myaffiliates_token eq $_->myaffiliates_token } $self->_get_exposures)
    {
        croak $self->client->loginid . ' already has pay_for_exposure token ' . $exposure->myaffiliates_token . ' set.';
    }

    push @{$self->_exposures_added}, $exposure;

    # creative info may have changed due to this addition, so clear everything
    $self->clear_creative_affiliate_id;
    $self->clear_creative_media_id;

    return 1;
}

## _get_exposures
#
# Returns all exposures, sorted by record_date (most recent first).
#
####
sub _get_exposures {
    my $self = shift;

    my @exposures;
    my @updated_ids = keys %{$self->_exposures_updated};

    # from DB
    foreach my $id (keys %{$self->_exposures_from_db}) {
        if (not grep { $id eq $_ } @updated_ids) {
            push @exposures, $self->_exposures_from_db->{$id};
        }
    }

    # updated (and to be written to DB)
    foreach my $exposure (values %{$self->_exposures_updated}) {
        push @exposures, $exposure;
    }

    # added (to be written to DB)
    push @exposures, @{$self->_exposures_added};

    # reverse chronological order
    @exposures = sort { $b->exposure_record_date->epoch <=> $a->exposure_record_date->epoch } @exposures;
    return @exposures;
}

=head2 save

Will save all added and/or updated exposures to disk.

=cut

sub save {
    my $self = shift;

    foreach my $exposure (values %{$self->_exposures_updated}) {
        $exposure->set_db('write');
        $exposure->save();
    }

    foreach my $exposure (@{$self->_exposures_added}) {
        $exposure->set_db('write');
        $exposure->save();
    }

    # clear everything; added and updated exposures are now in DB,
    # and so have new ids created by DB next time we access _exposures_from_db
    $self->_clear_exposures_added;
    $self->_clear_exposures_updated;
    $self->_clear_exposures_from_db;

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

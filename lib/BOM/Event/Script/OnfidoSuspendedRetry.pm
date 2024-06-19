package BOM::Event::Script::OnfidoSuspendedRetry;

=head1 NAME

BOM::Event::Script::OnfidoSuspendedRetry - Construct required service objects

=head1 DESCRIPTION

Provides a retry mechanism for POI uploads (manual) attempted during planned Onfido outage periods.

=cut

use strict;
use warnings;

use Moo;
use BOM::Platform::Event::Emitter;
use Future::AsyncAwait;
use BOM::Event::Services;
use IO::Async::Loop;
use BOM::User::Onfido;
use DataDog::DogStatsd::Helper;
use BOM::User;
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Platform::S3Client;
use Locale::Codes::Country qw(country_code2code);
use BOM::Platform::Event::Emitter;

=head2 loop

Returns a L<IO::Async::Loop>

=cut

has loop => (
    is      => 'ro',
    default => sub {
        IO::Async::Loop->new;
    },
);

=head2 services

Returns a L<BOM::Event::Services>

=cut

has services => (
    is      => 'lazy',
    default => sub {
        my $self     = shift;
        my $services = BOM::Event::Services->new;
        $self->loop->add($services);
        $services;
    },
);

=head2 onfido

Provides a wrapper instance for communicating with the Customerio web API.
It's a singleton - we don't want to leak memory by creating new ones for every event.

=cut

has onfido => (
    is      => 'lazy',
    default => sub {
        my $self = shift;

        return $self->services->onfido;
    },
);

=head2 run

Scans through the Redis ZSET looking for clients that have manually uploaded their documents during Onfido outages, 
this is when the `system.suspend.onfido` dynamic setting is enabled.

It takes the following:

=over 4

=item * C<$limit> - optional limit for the ZSET scanning, defaults to 100.

=back

Returns a L<Future> that will resolve to C<undef>.

=cut

async sub run {
    my ($self, $limit) = @_;
    BOM::Config::Runtime->instance->app_config->check_for_update();

    if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido) {
        DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.true');
        return undef;
    } else {
        DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.false');
    }

    my $redis = $self->services->redis_events_write();

    await $redis->connect;

    # processes up to 100 of these clients hourly
    # with a 10 second delay to avoid throttling

    my $users = await $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'LIMIT', 0, $limit // 100);

    for my $binary_user_id ($users->@*) {
        await $redis->zrem(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, $binary_user_id);
        await $self->process($binary_user_id);
        await $self->loop->delay_future(after => 10);
    }
}

=head2 process 

Tries to execute the Onfido checks by utilizing the manually uploaded documents.

It takes the following:

=over 4

=item * C<$binary_user_id> - the binary user id of the client

=back

Returns a L<Future> that will resolve to C<undef>.

=cut

async sub process {
    my ($self, $binary_user_id) = @_;

    DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.retry', {tags => ["binary_user_id:$binary_user_id"]});

    try {
        my $user   = BOM::User->new(id => $binary_user_id) || die "invalid binary user id = $binary_user_id";
        my $client = $user->get_default_client;

        # we should be able to retrieve the following to continue:
        # - manually uploaded documents in the `uploaded` status
        # - the issuing country from these documents should be Onfido supported
        # - the document types from these documents should be Onfido supported
        # - a manually `uploaded` selfie

        my $documents = BOM::User::Onfido::candidate_documents($user);

        if ($documents) {
            my $onfido = $self->services->onfido();

            # first we need an applicant

            my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
            my $applicant_id   = $applicant_data->{id};

            unless ($applicant_id) {
                my $applicant = await $onfido->applicant_create(%{BOM::User::Onfido::applicant_info($client)});

                # saving data into onfido_applicant table
                BOM::User::Onfido::store_onfido_applicant($applicant, $client->binary_user_id) if $applicant && $applicant->id;
                $applicant_id = $applicant->id;
            }

            if ($applicant_id) {
                my $onfido_picture_ids = await $self->s3_onfido_acrobatics($client, $applicant_id, $documents);

                BOM::Platform::Event::Emitter::emit(
                    'ready_for_authentication',
                    {
                        loginid      => $client->loginid,
                        applicant_id => $applicant_id,
                        documents    => $onfido_picture_ids,
                    });

                DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.processed',
                    {tags => ["binary_user_id:$binary_user_id", "applicant:$applicant_id"]});
            } else {
                DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.no_applicant', {tags => ["binary_user_id:$binary_user_id"]});
            }
        } else {
            DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.no_documents', {tags => ["binary_user_id:$binary_user_id"]});
        }
    } catch {
        DataDog::DogStatsd::Helper::stats_inc('onfido.suspended.failure', {tags => ["binary_user_id:$binary_user_id"]});
    }
}

=head2 s3_onfido_acrobatics

This function downloads pictures from s3 and then uploads them into Onfido.

It takes the following:

=over 4

=item * C<$client> - the current L<BOM::User::Client> instance

=item * C<$applicant_id> - the current Onfido applicant id (string)

=item * C<$documents> - the candidates documents as returned by L<BOM::User::Onfido>

=back

Return an arrayref full of Onfido uploaded document ids.

=cut

async sub s3_onfido_acrobatics {
    my ($self, $client, $applicant_id, $documents) = @_;
    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    my $onfido    = $self->services->onfido();

    # we have to download the raw pictures from s3 and upload them to Onfido
    my $selfie_raw = await $s3_client->download($documents->{selfie}->file_name);

    # upload to Onfido
    my $selfie = await $onfido->live_photo_upload(
        filename     => $documents->{selfie}->file_name,
        applicant_id => $applicant_id,
        data         => $selfie_raw,
    );

    # store the onfido selfie
    BOM::User::Onfido::store_onfido_live_photo($selfie, $applicant_id);

    # do the same with all the documents
    my @onfido_documents;

    for my $document ($documents->{documents}->@*) {
        my $document_raw = await $s3_client->download($document->file_name);
        my $country      = $document->issuing_country // $client->place_of_birth // $client->residence;
        my $type         = $document->document_type;
        my $side         = $document->file_name =~ /_front\./ ? 'front' : 'back';

        # upload to Onfido
        my $onfido_document = await $onfido->document_upload(
            filename        => $document->file_name,
            applicant_id    => $applicant_id,
            data            => $document_raw,
            issuing_country => uc(country_code2code($country, 'alpha-2', 'alpha-3') // ''),
            type            => $type,
            side            => $side,
        );

        # store the onfido document
        BOM::User::Onfido::store_onfido_document($onfido_document, $applicant_id, $country, $type, $side);

        push @onfido_documents, $onfido_document->id;
    }

    return [@onfido_documents, $selfie->id];
}

1;

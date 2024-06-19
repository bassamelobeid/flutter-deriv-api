package BOM::Platform::Sendbird::Webhook::Collector;

use strict;
use warnings;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Digest::HMAC;
use Digest::SHA qw(hmac_sha256_hex);
use BOM::Config;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Platform::Event::Emitter;

use parent qw(Mojolicious::Controller);

=head2 collect

Entrypoint for sendbird webhook.

=cut

sub collect {
    my ($self) = @_;

    try {
        die 'not a valid sendbird request' unless $self->validates;
        $self->render(json => 'ok') if $self->save_message_data;
        $self->rendered(200);
    } catch ($error) {
        stats_inc('bom_platform.sendbird.webhook.missing_signature_header') if $error =~ /no signature header found/;
        stats_inc('bom_platform.sendbird.webhook.signature_mismatch')       if $error =~ /not a valid sendbird request/;

        $self->rendered(401);
    }
}

=head2 save_message_data

Saves data from sendbird webhook, check whether the current json payload is from a message. 
Ensures data is good enough before saving. Some payloads might be dropped due to missing fields.

Returns,
    true if reaches event emit, false otherwise

=cut

sub save_message_data {
    my ($self)    = @_;
    my $json      = $self->req->json;
    my @foul_keys = ();

    return 1 if ($json->{category} && $json->{category} !~ /:message_send$/);

    push @foul_keys, 'type'                unless $json->{type};
    push @foul_keys, 'category'            unless $json->{category};
    push @foul_keys, 'payload.created_at'  unless $json->{payload}->{created_at};
    push @foul_keys, 'payload.message_id'  unless $json->{payload}->{message_id};
    push @foul_keys, 'channel.channel_url' unless $json->{channel}->{channel_url};
    push @foul_keys, 'sender.user_id'      unless $json->{sender}->{user_id};

    if (($json->{type} // '') eq 'FILE') {
        push @foul_keys, 'payload.url' unless $json->{payload}->{url};
    } else {
        push @foul_keys, 'payload.message' unless $json->{payload}->{message};
    }

    return $self->_unexpected_format(@foul_keys) if @foul_keys;

    BOM::Platform::Event::Emitter::emit(
        p2p_chat_received => {
            message_id => $json->{payload}->{message_id},
            created_at => $json->{payload}->{created_at},
            user_id    => $json->{sender}->{user_id},
            channel    => $json->{channel}->{channel_url},
            type       => $json->{type},
            message    => $json->{payload}->{message} // '',
            url        => $json->{payload}->{url}     // '',
        });
    stats_inc('bom_platform.sendbird.webhook.messages_received');
    return 1;
}

=head2 _unexpected_format

Sends out metric to datadog with foul key in payload as a tag.

=over 4

=item C<$unexpected> the foul key

=back

Return,
    always returns undef so is clear we didn't even try to save this bogus payload.

=cut

sub _unexpected_format {
    my ($self, @foul_keys) = @_;
    stats_inc('bom_platform.sendbird.webhook.bogus_payload', {tags => [map { "foul_key:$_" } @foul_keys]});
    return;
}

=head2 validates

Determines whether the request is a valid sendbird webhook push.

Returns,
    true for a valid signature, false otherwise

=cut

sub validates {
    my ($self)   = @_;
    my $req      = $self->req;
    my $sig      = $req->headers->header('x-sendbird-signature') or die 'no signature header found';
    my $config   = BOM::Config::third_party();
    my $token    = $config->{sendbird}->{api_token} // die 'sendbird api token is missing';
    my $expected = hmac_sha256_hex($req->body, $token);

    return $sig eq $expected;
}

1;

package BOM::Platform::Sendbird::Webhook::Collector;

use strict;
use warnings;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{SENDBIRD_LOG_LEVEL} // 'info';
use Syntax::Keyword::Try;
use Digest::HMAC;
use Digest::SHA qw(hmac_sha256_hex);
use BOM::Config;
use BOM::Database::ClientDB;
use DataDog::DogStatsd::Helper qw(stats_inc);

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
    } catch {
        $log->errorf('Request failure: %s', $@);
        $self->rendered(401);
    }
}

=head2 save_message_data

Saves data from sendbird webhook, check whether the current json payload is from a message. 
Ensures data is good enough before saving. Some payloads might be dropped due to missing fields.

Returns,
    true for database insert performed, false otherwise

=cut

sub save_message_data {
    my ($self) = @_;
    my $json = $self->req->json;

    return $self->_unexpected_format('type')                unless $json->{type};
    return $self->_unexpected_format('category')            unless $json->{category} =~ /:message_send$/;
    return $self->_unexpected_format('payload.created_at')  unless $json->{payload}->{created_at};
    return $self->_unexpected_format('payload.message_id')  unless $json->{payload}->{message_id};
    return $self->_unexpected_format('channel.channel_url') unless $json->{channel}->{channel_url};
    return $self->_unexpected_format('sender.user_id')      unless $json->{sender}->{user_id};

    if ($json->{type} eq 'FILE') {
        return $self->_unexpected_format('payload.url') unless $json->{payload}->{url};
    } else {
        return $self->_unexpected_format('payload.message') unless $json->{payload}->{message};
    }

    return $self->p2p_chat_message_add([
        $json->{payload}->{message_id}, $json->{payload}->{created_at}, $json->{sender}->{user_id}, $json->{channel}->{channel_url},
        $json->{type},                  $json->{payload}->{message},    $json->{payload}->{url},
    ]);
}

=head2 _unexpected_format

Prints out a debug message for foul key in payload.

=over 4

=item C<$unexpected> the foul key

=back

Return,
    always returns false so is clear we didn't even try to save this bogus payload.

=cut

sub _unexpected_format {
    my ($self, $unexpected) = @_;
    $log->debugf('Bogus payload: unexpected %s', $unexpected);
    return;
}

=head2 p2p_chat_message_add

Runs the DB function to add message.

=over 4

=item C<$data> an arrayref with data to save

=back

Returns,
    true for database insert performed, false otherwise

=cut

sub p2p_chat_message_add {
    my ($self, $data) = @_;

    my $result = $self->_get_db->run(
        fixup => sub {
            $_->do(q{SELECT * FROM data_collection.p2p_chat_message_add(?,?,?,?,?,?,?)}, undef, @{$data});
        });

    stats_inc('bom_platform.sendbird.webhook.messages_received');
    return $result > 0;
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

=head2 _get_db

Returns an instance of ClientDB for the collector DB.

=cut

sub _get_db {
    return BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic;
}

1;

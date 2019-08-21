package BOM::Platform::Token::API;

use strict;
use warnings;

use Moo;

use BOM::Database::Model::AccessToken;

use Bytes::Random::Secure;
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;
use BOM::Config::RedisReplicated;
use Log::Any ();

use constant {
    NAMESPACE       => 'TOKEN',
    NAMESPACE_BY_ID => 'TOKENS_BY_ID',
    TOKEN_LENGTH    => 15,
};

my %supported_scopes = map { $_ => 1 } ('read', 'trade', 'payments', 'admin');

sub create_token {
    my ($self, $loginid, $display_name, $scopes, $ip) = @_;

    $self->_log->fatal("loginid is required")      unless $loginid;
    $self->_log->fatal("display_name is required") unless $display_name;

    $scopes = [grep { $supported_scopes{$_} } @$scopes];
    my $token = $self->_generate_token(TOKEN_LENGTH);

    my $data = {
        type          => 'api',
        display_name  => $display_name,
        scopes        => $scopes,
        valid_for_ip  => $ip // '',
        creation_time => time,
        loginid       => $loginid,
        token         => $token,
        last_used     => 0,
    };

    # save in database for persistence
    $self->_api_model->save_token($data);

    my $writer    = $self->_redis_write;
    my $redis_key = $self->_make_key($token);
    $data->{scopes} = encode_json_utf8($data->{scopes});

    $writer->multi;
    $writer->hmset($redis_key, $_, %$data);
    $writer->hset($self->_make_key_by_id($data->{loginid}), $data->{display_name}, $token);
    $writer->exec;

    return $token;
}

=head2 get_token_details

returns a hash reference containing details of a token

=cut

sub get_token_details {
    my ($self, $token) = @_;

    my $key = $self->_make_key($token);
    my %details = @{$self->_redis_read->hgetall($key) // []};

    $details{scopes} = decode_json_utf8($details{scopes}) if $details{scopes};

    $self->_redis_write->hset($key, 'last_used', time);

    # last_used is expected as string in the API schema
    $details{last_used} = Date::Utility->new($details{last_used})->datetime if $details{last_used};

    return \%details;
}

sub get_scopes_by_access_token {
    my ($self, $token) = @_;

    my $details = $self->get_token_details($token);

    return @{$details->{scopes}} if $details and ref $details->{scopes} eq 'ARRAY';
    return ();
}

=head2 get_tokens_by_loginid

Returns all API tokens belong to the provided loginid.

This could be slow if loginid has a lot of tokens. Use with caution!

=cut

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    my $tokens = $self->_redis_read->hvals($self->_make_key_by_id($loginid));

    return [sort { $a->{display_name} cmp $b->{display_name} } map { _cleanup($self->get_token_details($_)) } @$tokens];
}

=head2 get_token_count_by_loginid

Return the number of tokens available for the provided loginid

=cut

sub get_token_count_by_loginid {
    my ($self, $loginid) = @_;

    return $self->_redis_read->hlen($self->_make_key_by_id($loginid));
}

=head2 is_name_taken

Do we have the same API token display name for this loginid

=cut

sub is_name_taken {
    my ($self, $loginid, $display_name) = @_;

    return $self->_redis_read->hexists($self->_make_key_by_id($loginid), $display_name);
}

=head2 remove_by_loginid

removes all API tokens for loginid

=cut

sub remove_by_loginid {
    my ($self, $loginid) = @_;

    my $key_by_id = $self->_make_key_by_id($loginid);
    my %all       = @{$self->_redis_read->hgetall($key_by_id)};
    my $redis     = $self->_redis_write;

    foreach my $name (keys %all) {
        my $token_details = $self->get_token_details($all{$name});
        #remove token from database first before removing it from redis
        $self->_api_model->remove_by_token($token_details->{token}, $loginid);

        $redis->multi;
        $redis->del($self->_make_key($all{$name}));
        $redis->hdel($key_by_id, $name);
        $redis->exec;
    }

    return 1;
}

=head2 remove_by_token

removes token for loginid

=cut

sub remove_by_token {
    my ($self, $token, $loginid) = @_;

    my $key_by_id = $self->_make_key_by_id($loginid);

    my %all = reverse @{$self->_redis_read->hgetall($key_by_id)};

    my $redis = $self->_redis_write;

    my $token_details = $self->get_token_details($token);
    #remove token from database first before removing it from redis
    $self->_api_model->remove_by_token($token_details->{token}, $loginid);

    $redis->multi;
    $redis->del($self->_make_key($token));
    $redis->hdel($key_by_id, $all{$token});
    $redis->exec;

    return 1;
}

my @chars = ("A" .. "Z", 0 .. 9, "a" .. "z");

=head2 generate_token

generates random token for the provided length.

=cut

sub generate_token {
    my ($self, $length) = @_;

    return Bytes::Random::Secure->new(
        Bits        => 160,
        NonBlocking => 1,
    )->string_from(join('', @chars), $length);
}

### PRIVATE ###
sub _cleanup {
    my $token = shift;
    delete $token->{$_} for qw(creation_time loginid type);
    return $token;
}

has _api_model => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_api_model'
);

sub _build_api_model {
    return BOM::Database::Model::AccessToken->new;
}

has _redis_read => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_redis_read',
);

has _redis_write => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_redis_write',
);

sub _build_redis_read {
    return BOM::Config::RedisReplicated::redis_auth();
}

sub _build_redis_write {
    return BOM::Config::RedisReplicated::redis_auth_write();
}

sub _make_key {
    my ($self, $token) = @_;

    return join('::', (NAMESPACE, $token));
}

sub _make_key_by_id {
    my ($self, $id) = @_;

    $id = [$id] if ref $id ne 'ARRAY';

    return join('::', (NAMESPACE_BY_ID, @$id));
}

has _log => (
    is      => 'ro',
    default => sub { Log::Any->get_logger },
);

1;

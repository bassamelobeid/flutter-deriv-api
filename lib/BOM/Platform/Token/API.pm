package BOM::Platform::Token::API;

=head1 NAME

BOM::Platform::Token::API - creates and saves API token to both auth redis and auth database.

=cut

=head2 DESCRIPTION

    use BOM::Platform::Token::API;

    my $obj = BOM::Platform::Token::API->new;
    # creates new token
    my $token = $obj->create_token('CR1234', 'testtoken', ['read','write']);
    # delete token
    $obj->remove_by_token($token);

=cut

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
    my $token = $self->generate_token(TOKEN_LENGTH);

    my $data = {
        type          => 'api',
        display_name  => $display_name,
        scopes        => $scopes,
        valid_for_ip  => $ip // '',
        creation_time => Date::Utility->new->db_timestamp,
        loginid       => $loginid,
        token         => $token,
        last_used     => '',
    };

    # save in database for persistence
    $self->_db_model->save_token($data);

    $self->save_token_details_to_redis($data);

    return $token;
}

sub save_token_details_to_redis {
    my ($self, $data) = @_;

    my $token           = $data->{token};
    my $writer          = $self->_redis_write;
    my $redis_key_by_id = $self->_make_key_by_id($data->{loginid});

    $self->_log->fatal('display name must be unique.') if $writer->hexists($redis_key_by_id, $data->{display_name});

    $data->{scopes}        = encode_json_utf8($data->{scopes})                 if $data->{scopes} and ref $data->{scopes} eq 'ARRAY';
    $data->{creation_time} = Date::Utility->new($data->{creation_time})->epoch if $data->{creation_time};
    $data->{last_used}     = Date::Utility->new($data->{last_used})->epoch     if $data->{last_used};

    $writer->multi;
    $writer->hmset($self->_make_key($token), %$data);
    $writer->hset($redis_key_by_id, $data->{display_name}, $token);
    $writer->exec;

    return;
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
        my $token_details = $self->_db_model->get_token_details($all{$name});
        #remove token from database first before removing it from redis
        $self->_db_model->remove_by_token($token_details->{token}, $loginid);

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

    #remove token from database first before removing it from redis
    $self->_db_model->remove_by_token($token, $loginid);

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

sub update_cached_last_used {
    my ($self, $token, $last_used) = @_;

    $self->_log->fatal("token and last_used are required") unless $token and $last_used;
    my $key    = $self->_make_key($token);
    my $writer = $self->_redis_write;

    $writer->hset($key, 'last_used', Date::Utility->new($last_used)->epoch) if $writer->hexists($key, 'last_used');

    return;
}
### PRIVATE ###

has _db_model => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_db_model'
);

sub _build_db_model {
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

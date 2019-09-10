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
use BOM::Platform::Context qw (localize);

use constant {
    NAMESPACE       => 'TOKEN',
    NAMESPACE_BY_ID => 'TOKENS_BY_ID',
    TOKEN_LENGTH    => 15,
};

my %supported_scopes = map { $_ => 1 } ('read', 'trade', 'payments', 'admin');

sub create_token {
    my ($self, $loginid, $display_name, $scopes, $ip) = @_;

    die $self->_log->fatal("loginid is required")      unless $loginid;
    die $self->_log->fatal("display_name is required") unless $display_name;

    return {error => localize('alphanumeric with space and dash, 2-32 characters')} if $display_name !~ /^[\w\s\-]{2,32}$/;
    return {error => localize('Max 30 tokens are allowed.')} if $self->get_token_count_by_loginid($loginid) > 30;

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

    # save in database for persistence.
    # tokens will be saved in the database first before saving it in redis because
    # database will still be the source of truth for the API token
    my $success = $self->_db_model->save_token($data);
    $self->save_token_details_to_redis($data) if $success->{token};

    return $success->{token};
}

=head2 get_token_details

returns a hash reference containing details of a token

=cut

sub get_token_details {
    my ($self, $token, $update_last_used) = @_;

    $update_last_used //= 0;
    my $key = $self->_make_key($token);
    my %details = @{$self->_redis_read->hgetall($key) // []};

    $details{scopes} = decode_json_utf8($details{scopes}) if $details{scopes};

    $self->_redis_write->hset($key, 'last_used', time) if $update_last_used;

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

    my $tokens = $self->_redis_read->hkeys($self->_make_key_by_id($loginid));

    return [sort { $a->{display_name} cmp $b->{display_name} } map { _cleanup($self->get_token_details($_)) } @$tokens];
}

=head2 get_token_count_by_loginid

Return the number of tokens available for the provided loginid

=cut

sub get_token_count_by_loginid {
    my ($self, $loginid) = @_;

    return $self->_redis_read->hlen($self->_make_key_by_id($loginid));
}

sub save_token_details_to_redis {
    my ($self, $data) = @_;

    my $token  = $data->{token};
    my $writer = $self->_redis_write;

    $data->{scopes}        = encode_json_utf8($data->{scopes})                 if $data->{scopes} and ref $data->{scopes} eq 'ARRAY';
    $data->{creation_time} = Date::Utility->new($data->{creation_time})->epoch if $data->{creation_time};
    $data->{last_used}     = Date::Utility->new($data->{last_used})->epoch     if $data->{last_used};

    $writer->multi;
    $writer->hmset($self->_make_key($token), %$data);
    $writer->hset($self->_make_key_by_id($data->{loginid}), $token, 1);
    $writer->exec;

    return 1;
}

=head2 remove_by_loginid

removes all API tokens for loginid

=cut

sub remove_by_loginid {
    my ($self, $loginid) = @_;

    my $key_by_id = $self->_make_key_by_id($loginid);
    my %all       = @{$self->_redis_read->hgetall($key_by_id)};
    my $redis     = $self->_redis_write;

    foreach my $token (keys %all) {
        my $token_details = $self->get_token_details($token);
        $redis->multi;
        $redis->del($self->_make_key($token));
        $redis->hdel($key_by_id, $token);
        $redis->exec;
        #remove token from database happens after redis since it is the source of truth
        $self->_db_model->remove_by_token($token, ($token_details->{last_used} ? Date::Utility->new($token_details->{last_used})->db_timestamp : ''));

    }

    return 1;
}

=head2 remove_by_token

removes token for loginid

=cut

sub remove_by_token {
    my ($self, $token, $loginid) = @_;

    my $key_by_id     = $self->_make_key_by_id($loginid);
    my $token_details = $self->get_token_details($token);

    my $redis = $self->_redis_write;

    $redis->multi;
    $redis->del($self->_make_key($token));
    $redis->hdel($key_by_id, $token);
    $redis->exec;

    #remove token from database happens after redis since it is the source of truth
    $self->_db_model->remove_by_token($token, ($token_details->{last_used} ? Date::Utility->new($token_details->{last_used})->db_timestamp : ''));

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

=head2 token_exists

Check if token exists in auth redis. Returns a boolean.

=cut

sub token_exists {
    my ($self, $token) = @_;

    return $self->_redis_read->exists($self->_make_key($token));
}

### PRIVATE ###
sub _cleanup {
    my $token = shift;
    delete $token->{$_} for qw(creation_time loginid type);
    return $token;
}

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

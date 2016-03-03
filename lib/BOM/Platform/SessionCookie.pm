
=head1 NAME

BOM::Platform::SessionCookie - Session and Cookie Handling for Binary.com

=head1 SYNOPSIS

 my $cookie = BOM::Platform::SessionCookie(token => $token, email => $email);
 my $loginid = $cookie->loginid;
 if ($cookie->validate_session()){
    # we can trade
 };

=cut

package BOM::Platform::SessionCookie;
use Bytes::Random::Secure;
use JSON;
use Carp;
use Array::Utils qw (array_minus);

use BOM::System::RedisReplicated;

use strict;
use warnings;

=head1 DATA STRUCTURE AND ACCESSORS

The resulting cookie is a simple hashref, stored in Redis for a period of time
and retrieved with a token.

Very commonly used and stable (over api version) attributes have accesssors.

=head2 ACCESSORS (READ ONLY)

=over

=item loginid

The LoginID

=item loginat

the login time in seconds since epoch

=item email

the client email

=item token

the token to be stored in the cookie or similar

=back

=cut

# accessors for very frequently used attributes
sub loginid { $_[0]->{loginid} if ref $_[0] }    ## no critic
sub loginat { $_[0]->{loginat} if ref $_[0] }    ## no critic
sub email   { $_[0]->{email}   if ref $_[0] }    ## no critic
sub token   { $_[0]->{token}   if ref $_[0] }    ## no critic
sub clerk   { $_[0]->{clerk}   if ref $_[0] }    ## no critic

=head1 CONSTRUCTOR

=head2 new({token => $token})

Retrieves a session state structure from redis.

=head2 new({key1 => $value1, ...,)

Creates a new session and stores it in redis.

=cut

# default token parameters
my $STRING       = join '', 'a' .. 'z', 'A' .. 'Z', '0' .. '9';
my @REQUIRED     = qw(email);
my @ALLOWED      = qw(email loginid token expires_in loginat scopes clerk auth_token client_id expiration_time);
my $EXPIRES_IN   = 3600 * 24;
my $TOKEN_LENGTH = 48;

sub new {    ## no critic RequireArgUnpack
    my ($package) = shift;
    my $self = ref $_[0] ? $_[0] : {@_};
    if ($self->{token}) {
        $self = eval { JSON::from_json(BOM::System::RedisReplicated::redis_read()->get('LOGIN_SESSION::' . $self->{token})) } || {};
        return bless {}, $package unless $self->{token};
    } else {
        my @valid = grep { !$self->{$_} } @REQUIRED;
        croak "Error adding new session, missing: " . join(',', @valid)
            if @valid;

        my @passed = keys %$self;
        @valid = array_minus(@passed, @ALLOWED);
        croak "Error adding new session, contains keys:" . join(',', @valid) . " that are outside allowed keys" if @valid;

        # NOTE, we need to use the object interface here. Bytes::Random::Secure
        # also offers a function interface but that uses a RNG which is
        # initialized only once. If we happen to generate a session cookie for
        # whatever reason before forking children, all children would then
        # generate the same random sequence. Hence, better to re-seed the RNG
        # for every token.
        $self->{token} = Bytes::Random::Secure->new(
            Bits        => 160,
            NonBlocking => 1,
        )->string_from($STRING, $TOKEN_LENGTH);
        $self->{loginat} ||= time;
        BOM::System::RedisReplicated::redis_write()->set('LOGIN_SESSION::' . $self->{token}, JSON::to_json($self));
    }
    $self->{expires_in} ||= $EXPIRES_IN;
    $self->{issued_at} = time;
    BOM::System::RedisReplicated::redis_write()->expire('LOGIN_SESSION::' . $self->{token}, $self->{expires_in});
    return bless $self, $package;
}

=head1 METHODS

=head2 validate_session();

=cut

sub validate_session {
    my $self = shift;
    if ($self->{token}) {
        return 1;
    }
    return;
}

=head2 end_session

Deletes from redis

=cut

sub end_session {    ## no critic
    my $self = shift;
    return unless $self->{token};
    BOM::System::RedisReplicated::redis_write()->del('LOGIN_SESSION::' . $self->{token});
}

1;

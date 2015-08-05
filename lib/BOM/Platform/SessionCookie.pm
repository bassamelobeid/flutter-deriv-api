
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
use BOM::System::Chronicle;
use BOM::Utility::Random;
use JSON;
use Carp;

use strict;
use warnings;

=head1 DATA STRUCTURE AND ACCESSORS

The resulting cookie is a simple hashref, stored in Redis for a period of time
and retrieved with a token.

Very commonly used and stable (over api version) attributes have accesssors.

=head2 ACCESSORS (READ ONLY)

=over 

=item loginid

=item email

=item token

=back

=cut

# accessors for very frequently used attributes
sub loginid { $_[0]->{loginid} if ref $_[0] }    ## no critic
sub email   { $_[0]->{email}   if ref $_[0] }    ## no critic
sub token   { $_[0]->{token}   if ref $_[0] }    ## no critic
sub clerk   { $_[0]->{clerk}   if ref $_[0] }    ## no critic

=head1 CONSTRUCTOR

=head2 new({token => $token})

Retrieves a session state structure from redis.

=head2 new({key1 => $value1, ...,)

Creates a new session and stores it in redis.

=cut

# characters for token
my $string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';

my @required = qw(loginid email);

sub new {    ## no critic RequireArgUnpack
    my ($package) = shift;
    my $self = ref $_[0] ? $_[0] : {@_};
    if ($self->{token}) {
        $self = eval { JSON::from_json(BOM::System::Chronicle->_redis_read->get('LOGIN_SESSION::' . $self->{token})) } || {};
        return bless {}, $package unless $self->{token};
    } else {
        my @missing = grep { not exists $self->{$_} } @required;
        croak "Error adding new session, missing: " . join(',', @missing)
            if @missing;
        $self->{token} = BOM::Utility::Random->string_from($string, 128);
        BOM::System::Chronicle->_redis_write->set('LOGIN_SESSION::' . $self->{token}, JSON::to_json($self));
    }
    BOM::System::Chronicle->_redis_write->expire('LOGIN_SESSION::' . $self->{token}, 3600 * 24);
    $self->{issued_at}  = time;
    $self->{expires_in} = 3600 * 24;
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
    BOM::System::Chronicle->_redis_write->del('LOGIN_SESSION::' . $self->{token});
}

1;

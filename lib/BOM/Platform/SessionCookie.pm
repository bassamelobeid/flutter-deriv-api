
=head1 NAME

BOM::Platform::SessionCookie - Session and Cookie Handling for Binary.com

=head1 SYNOPSIS

 my $cookie = BOM::Platform::SessionCookie(token => $token, email => $email);
 my $loginid = $cookie->loginid;
 if ($cookie->validate_session('trade')){
    # we can trade
 };

=cut

package BOM::Platform::SessionCookie;
use BOM::System::Chronicle;
use BOM::Utility::Random;
use JSON;

use strict;
use warnings;

=head1 DATA STRUCTURE AND ACCESSORS

The resulting cookie is a simple hashref, stored in Redis for a period of time
and retrieved with a token.

Very commonly used and stable (over api version) attributes have accesssors.

Also scopes is a reserved word used for authorization.  Other keys an be passed
in and will be part of the hashref returned (can be accessed as values in a 
hashref).

=head2 ACCESSORS (READ ONLY)

=over 

=item loginid

=item email

=item token

=back

=cut

# accessors for very frequently used attributes
sub loginid { $_[0]->{loginid} }    ## no critic
sub email   { $_[0]->{email} }      ## no critic
sub token   { $_[0]->{token} }      ## no critic

=head1 CONSTRUCTOR

=head2 new({token => $token})

Retrieves a session state structure from redis.

=head2 new({key1 => $value1, ..., scopes => [@scopes])

Creates a new session and stores it in redis.

=cut

# characters for token
my $string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890-_';

sub new {    ## no critic RequireArgUnpack
    my ($package) = shift @_;
    my $self = ref $_[0] ? $_[0] : {@_};
    if ($self->{token}) {
        $self = JSON::from_json(BOM::System::Chronicle->_redis_read->get('LOGIN_SESSIN::' . $self->{token})) || {};
    } else {
        $self->{token} = BOM::Utility::Random->string_from($string, 128);
        BOM::System::Chronicle->_redis_write->set('LOGIN_SESSIN::' . $self->{token}, JSON::to_json($self));
    }
    BOM::System::Chronicle->_redis_write->expire('LOGIN_SESSIN::' . $self->{token}, 3600 * 24);
    return bless $self, $package;
}

=head1 METHODS

=head2 validate_session($scope);

Returns true if the session is valid and either there is no scope requested or
the scope is found in $self->{scopes}

=cut

sub validate_session {
    my $self  = shift;
    my $scope = shift;
    return unless $self->{token};
    return not $scope or grep { $_ eq $scope } @{$self->{scopes}};
}

=head2 end_session

Deletes from redis

=cut

sub end_session {    ## no critic
    my $self = shift;
    BOM::System::Chronicle->_redis_write->set('LOGIN_SESSIN::' . $self->{token});
}

1;

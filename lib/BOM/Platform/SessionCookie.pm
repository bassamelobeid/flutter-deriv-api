package BOM::Platform::SessionCookie;

=head1 NAME

BOM::Platform::SessionCookie

=head1 DESCRIPTION

This class will provide Session Cookie's Name & Value.

=head1 METHODS

=head2 $class->new(loginid => $login, token => $token, [clerk => $clerk])

Create new object with the given attributes' values

=cut

use 5.010;
use Moose;
use BOM::Platform::Runtime;
use BOM::Utility::Crypt;
use BOM::Utility::Log4perl qw(get_logger);

sub _crypt {
    state $crypt = BOM::Utility::Crypt->new(keyname => 'cookie');
    return $crypt;
}

=head2 $class->from_value($cookie_value)

Build instance from the encrypted cookie value. If verification/decryption fails, method will return false.

=cut

sub from_value {
    my ($class, $value) = @_;
    my $ref = $class->_crypt->decrypt_payload(value => $value);
    return if not $ref or ($ref->{expires} and $ref->{expires} < time) or not $ref->{token} or not $ref->{email};
    return $class->new($ref);
}

sub validate_session {
    my $self = shift;
    require BOM::Platform::Authorization;    # breaks a cyclic compilation chain (db->request->session->authdb)
    my $token = BOM::Platform::Authorization::Token->validate(token => $self->token);
    return 1 if $token;
    get_logger->info("Token not validated.  Reason: " . BOM::Platform::Authorization::Token->last_err);
    return;
}

=head2 loginid, token, email, clerk

Return appropriate client attribute.  Tokens are essentially open auth tokens.

=cut

has [qw( loginid token email )] => (
    is       => 'ro',
    required => 1,
);

#Deprecated.
has clerk => (is => 'ro');

has expires => (is => 'rw');

=head2 $self->as_hash

Return attributes as a hash reference

=cut

sub as_hash {
    my $self = shift;
    my $res  = {};
    for (qw(email loginid token clerk expires)) {
        $res->{$_} = $self->$_ if $self->$_;
    }

    return $res;
}

=head2 $self->value

Return attributes as a serialized encrypted/signed value suitable for assigning to login cookie

=cut

sub value {
    my $self = shift;
    return $self->_crypt->encrypt_payload(data => $self->as_hash);
}

=head2 $self->end_session

Removes the token from the db and the cookie.

=cut

sub end_session {
    my ($self) = @_;
    my $token = delete $self->{token};
    return BOM::Platform::Authorization->revoke_token(token => $token)
        if $token;
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

shuwn yuan, C<< <shuwnyuan at regentmarkets.com> >>

RMG Company

=head1 COPYRIGHT

(c) 2012 RMG Technology (Malaysia) Sdn Bhd

=cut

1;

package BOM::Platform::Token::Verification;

=head1 NAME

Email verification token handler

=head1 SYNOPSIS
 my $token = BOM::Platform::Token::Verification->new({created_for => 'lost_password', email => 'abc@binary.com', expires_in => 3600});
 my $token = BOM::Platform::Token::Verification->new({token => $token});

 The resulting token is a simple hashref, stored in Redis for a period of time
 and retrieved with a token.
=cut

use Bytes::Random::Secure;
use JSON;
use Carp;
use Array::Utils qw (array_minus);
use Digest::MD5 qw(md5_hex);

use BOM::System::RedisReplicated;

use strict;
use warnings;

=head1 CONSTRUCTOR

=head2 new({token => $token})
 Retrieves a token state structure from redis.

=head2 new({key1 => $value1, ...,)
 Creates a new token and stores it in redis.

=cut

sub email { $_[0]->{email} if ref $_[0] }    ## no critic
sub token { $_[0]->{token} if ref $_[0] }    ## no critic

sub new {                                    ## no critic RequireArgUnpack
    my ($package) = shift;

    my $self = ref $_[0] ? $_[0] : {@_};
    if ($self->{token}) {
        $self = eval { JSON::from_json(BOM::System::RedisReplicated::redis_read()->get('VERIFICATION_TOKEN::' . $self->{token})) } || {};
        return bless {}, $package unless $self->{token};
    } else {
        my @valid = grep { !$self->{$_} } qw(email created_for);
        croak "Error creating new verification token, missing: " . join(',', @valid)
            if @valid;

        my @passed = keys %$self;
        @valid = array_minus(@passed, qw(email token expires_in created_for));
        croak "Error adding new verification token, contains keys:" . join(',', @valid) . " that are outside allowed keys" if @valid;

        $self->{token} = Bytes::Random::Secure->new(
            Bits        => 160,
            NonBlocking => 1,
        )->string_from(join('', 'a' .. 'z', 'A' .. 'Z', '0' .. '9'), 48);

        my $key = md5_hex($self->{created_for} . $self->{email});
        if (my $token = BOM::System::RedisReplicated::redis_read()->get('VERIFICATION_TOKEN_INDEX::' . $key)) {
            BOM::System::RedisReplicated::redis_write()->del('VERIFICATION_TOKEN::' . $token);
        }

        BOM::System::RedisReplicated::redis_write()->set('VERIFICATION_TOKEN::' . $self->{token}, JSON::to_json($self));
        $self->{expires_in} ||= 3600;
        BOM::System::RedisReplicated::redis_write()->set('VERIFICATION_TOKEN_INDEX::' . $key, $self->{token});
        BOM::System::RedisReplicated::redis_write()->expire('VERIFICATION_TOKEN::' . $self->{token}, $self->{expires_in});
    }
    return bless $self, $package;
}

=head1 METHODS

=head2 validate_token();

=cut

sub validate_token {
    my $self = shift;
    if ($self->{token}) {
        return 1;
    }
    return;
}

=head2 delete_token

Deletes from redis

=cut

sub delete_token {    ## no critic
    my $self = shift;
    return unless $self->{token};
    BOM::System::RedisReplicated::redis_write()->del('VERIFICATION_TOKEN::' . $self->{token});
    BOM::System::RedisReplicated::redis_write()->del('VERIFICATION_TOKEN_INDEX::' . md5_hex($self->{created_for} . $self->{email}))
        if ($self->{created_for} and $self->{email});
}

1;

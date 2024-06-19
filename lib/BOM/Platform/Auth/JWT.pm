package BOM::Platform::Auth::JWT;

use strict;
use warnings;

no indirect;

use feature "state";

use Path::Tiny;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Crypt::JWT      qw(decode_jwt);
use Array::Utils    qw( intersect );

use BOM::Config;

=head1 NAME

BOM::Platform::Auth::JWT - A module for validating JSON Web Tokens

=head1 SYNOPSIS

    use BOM::Platform::Auth::JWT;

    my $jwt = BOM::Platform::Auth::JWT->new();

    my $result = $jwt->validate(token => 'YOUR_JWT_TOKEN');

=head1 DESCRIPTION

This module provides methods to validate JSON Web Tokens.

=head1 METHODS

=cut

=head2 new

Creates a new instance of BOM::Platform::Auth::JWT.

=cut

sub new {
    my $class = shift;

    return bless {}, $class;
}

=head2 validate

Takes a JSON Web Token as an argument and validates it. Returns the decoded token data if valid, otherwise it will die with an error message.

=cut

sub validate {
    my ($self, %args) = @_;

    my $issuer_details = $self->issuer_details();

    die "Missing issuer details to validate the token (JWT)" unless $issuer_details;

    my $keys = $self->load_keys(keys_path => $issuer_details->{keys_path});

    die "Missing authentication keys to validate the token (JWT): ${\$issuer_details->{keys_path}}" unless $keys;

    my $audience = $issuer_details->{application_id};
    # Warn only once, after we've reported this on the first request further notifications are
    # not going to improve matters at all
    state $audience_warning = do {
        $log->warnf("No audience is defined for authentication token (JWT), it will *not* check whether token was generated for our application")
            unless $audience;
    };

    my ($header, $data) = decode_jwt(
        # The provided JWT to check
        token => $args{token},
        # Current certs
        kid_keys => $keys,
        # Return header information
        decode_header => 1,
        # Provide 2 seconds of tolerance for expiry/start-at times, since our NTP sync
        # has no guarantees of matching up closely with Cloudflare
        leeway => 2,
        # Ensure we verify access time, "not-before" and "expiry" - these settings
        # are currently the default, but we want to be explicit here to remind people
        # that these are important
        verify_iat => 1,
        verify_nbf => 1,
        verify_exp => 1,
        # Also verify whether the issuer (Cloudflare) and audience (application) match our service
        verify_iss => $issuer_details->{issuer},
        verify_aud => sub {
            my $provided = shift;
            # Audience so far seems to be an arrayref, but according to Crypt::JWT it normally expects a string - let's support both
            ref($provided)
                ? intersect(@$audience, @$provided)
                : (grep { $provided eq $_ } $audience->@*);
        },
        # ... but don't check the subject (unique identifier for the person), because this will be different
        # for each person and we don't yet know who is signing in...
        verify_sub => undef,
    );

    die 'Cannot validate token (JWT)' unless $header and $data;

    my $user_info = $data->{custom};
    die sprintf 'Mismatched email: custom contains %s but top-level has %s', $user_info->{email}, $data->{email}
        unless $user_info->{email} eq $data->{email};

    my $email   = $data->{email};
    my $country = $data->{country};

    return {
        id             => $data->{sub},
        email          => $email,
        country        => $country,
        name           => $user_info->{name},
        identity_nonce => $data->{identity_nonce},
        details        => $user_info,
        expiry         => $data->{exp},
        issuer         => $data->{iss},
    };
}

=head2 load_keys

Loads the keys for validating the JSON Web Tokens from the specified path.

=cut

sub load_keys {
    my ($self, %args) = @_;

    my $key_path = $args{keys_path} // $self->issuer_details()->{keys_path};

    return undef unless $key_path;

    my $path = path($key_path);

    return undef unless $path->exists and $path->size;

    return decode_json_utf8($path->slurp_utf8);
}

=head2 issuer_details

Returns the JWT issuer details from the Config module.

=cut

sub issuer_details {
    return BOM::Config::third_party()->{cloudflared};
}

=head2 logout_url

Returns the logout url based on the issuer from the Config module.

=cut

sub logout_url {
    return BOM::Config::third_party()->{cloudflared}->{issuer} . '/cdn-cgi/access/logout';
}

1;

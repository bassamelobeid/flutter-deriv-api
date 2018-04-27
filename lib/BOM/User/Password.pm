package BOM::User::Password;
use strict;
use warnings;

use Crypt::ScryptKDF qw(scrypt_hash scrypt_hash_verify);
use Digest::SHA;
use Encode;
use Mojo::Util;

=head1 NAME

BOM::User::Password - Password hashing module for BOM

=cut

# TODO:  Move to String::Compare::ConstantTime since Crypt::NamedKeys already
# requires this.

# "Constants"

# update every time the algorithm changes
sub ALGO_VERSION { return 2; }

=head1 SYNOPSIS

 To create a password hash for db storage:

 my $pwhash = BOM::User::Password::hashpw($password);

 To verify a password hash:

 my $matched = BOM::User::Password::checkpw($password, $pwhash)

=head1 DESCRIPTION

This module provides the basic password vault for the web site and all 
functions relating.  Password strings contain all information needed to
validate them including salt and algorithm version. In the current version
both salt and encrypted password are handled by L<Crypt::ScryptKDF|scrypt_hash>.
So the password is like this:

    2*SCRYPT:16384:8:1:lkUvbSyxJduZAvgseqZvyg==:pks9+s4GDdbsZklk5BNPuVbOlM+rzsXWh2WDCxhFeJc=

=head1 FUNCTIONS

=head2 ALGO_VERSION

Returns the current algorithm version.

=head2 hashpw($string)

Returns a password hash string in a format with algorithm version control, salt
and a hash.

The version 1 format is

$algo_version*$salt*password


The version 2 format is
$algo_version*password
The salt will be handled directly by Crypt::ScryptKDF::scrypt_hash

Currently a maximum length of 200 is enforced and an exception thrown if 
too long.

=cut

sub hashpw {
    my $password = shift;
    # we need encode password, otherwise it is possible to report the warning "Wide character in subroutine entry";
    $password = Encode::encode_utf8($password);
    die 'password too long, possible DOS attack' if length($password) > 200;
    my $hash = scrypt_hash($password, \16);
    return ALGO_VERSION . "*$hash";
}

=head2 checkpw($string, $hashed) 

Returns true if the password matches when hashed.  False otherwise.

=cut

# This is a dispatch table for algorithm -> checking routines.  It is here so
# we can safely add new algorithms in backwards-compatible ways.  When adding a
# new algorithm, add the check here in algo_num => sub form.  true means passes,
# false means fails.

my $passwd_check = {
    0 => sub {
        my ($pwhash, $password) = @_;
        _legacy_pwcheck($password, $pwhash->{hash});
    },
    1 => sub {
        my ($pwhash, $password) = @_;
        $password = Encode::encode_utf8($password);
        return Mojo::Util::secure_compare($pwhash->{hash}, Crypt::ScryptKDF::scrypt_b64($password, $pwhash->{salt}));
    },
    2 => sub {
        my ($pwhash, $password) = @_;
        $password = Encode::encode_utf8($password);
        return scrypt_hash_verify($password, $pwhash->{hash});
    }
};

sub checkpw {
    my ($password, $hashstring) = @_;
    return if length($password) > 200;    # fail if too long
    return unless defined $password;      # always fail when no password

    my $pwhash = _pwstring_to_hashref($hashstring);
    return $passwd_check->{$pwhash->{version}}($pwhash, $password);
}

# private functions

sub _pwstring_to_hashref {
    my $string = shift;
    # default version 0
    my $result = {
        version => 0,
        hash    => $string,
        salt    => undef
    };

    return $result unless $string =~ s/^(\d+)\*//;

    $result->{version} = $1;
    if ($result->{version} == 1) {
        ($result->{salt}, $result->{hash}) = split /\*/, $string;
        return $result;
    }
    if ($result->{version} == 2) {
        $result->{hash} = $string;
        return $result;
    }

    #Shouldn't get to here.
    die "Don't support the format of password $string.";
}

sub _legacy_pwcheck {
    my ($passwd, $hash) = @_;
    if ($hash =~ /^6\$/) {
        return Mojo::Util::secure_compare(crypt($passwd, $hash), $hash);
    } elsif (length($hash) == 64) {    # legacy sha256 hash, no salt
        return Mojo::Util::secure_compare(_legacy_sha256($passwd), $hash);
    } else {                           # legacy crypt for chashier lock passwords
        $hash =~ /^(..)/;
        my $salt = $1;
        return Mojo::Util::secure_compare(crypt($passwd, $salt), $hash);
    }
}

sub _legacy_sha256 {
    my ($password) = shift;
    return unless $password;
    return Digest::SHA::sha256_hex($password);
}

=head1 HOW TO CHANGE PASSWORD ALGORITHMS IN THE FUTURE

This module is designed to be future-safe, allowing the web site to change
password hashing algorithms over time as needs change, tuning for work factor
and other things.

The password strings are encoded using * as a field separator.  The three
fields are algorithm version, salt, and hash.

=head2 STEP 1, Add handling for password comparison for the new algorithm

Please note, your update will hit different servers at different times.  Servers
must all be able to compare with the new algorithm before any choose to hash
with the new algorith,

To do this, add conditional logic or a dispatch table, based on the algorithm
number (the first field in the password hash string).  This allows you to select
based on the algorithm specified.  In essence, this structure allows you to 
always know how a password was hashed when you want to compare, so add your 
comparisons first, and deploy that to all servers in the first release.

=head2 STEP 2, Change the hashing

In the second release, you can safely change the hashing approach.

=cut

1;

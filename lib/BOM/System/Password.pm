
=head1 NAME

BOM::System::Password - Password hashing module for BOM

=cut

package BOM::System::Password;
use Crypt::ScryptKDF;
use Crypt::Salt;
use Digest::SHA;
use strict;
use warnings;

use Mojo::Util;

# TODO:  Move to String::Compare::ConstantTime since Crypt::NamedKeys already
# requires this.

# "Constants"

# update every time the algorithm changes
sub ALGO_VERSION { return 1; }

=head1 SYNPOSIS

 To create a password hash for db storage:

 my $pwhash = BOM::System::Password::hashpw($password);

 To verify a password hash:

 my $matched = BOM::System::Password::checkpw($password, $pwhash)

=head1 DESCRIPTION

This module provides the basic password vault for the web site and all 
functions relating.  Password strings contain all information needed to
validate them including salt and algorithm version.  The current usage is to use
* to separate fields and ^ to separate subfields.  So a password string may
look like:

  1*$5$bababa*g1fvvG0AVyYI23n4EmOdtYqtMrfV6FijVHqbQzZi7F4

=head1 FUNCTIONS

=head2 ALGO_VERSION

Returns the current algorithm version.

=head2 hashpw($string)

Returns a password hash string in a format with algorithm version control, salt
and a hash.

The current format is

$algo_version*$salt*password

Currently a maximum length of 200 is enforced and an exception thrown if 
too long.

=cut

sub _salt {
    my $string = '';
    $string .= salt() for 1 .. 8;
    return $string;
}

sub hashpw {
    my $password = shift;
    $password = shift if $password eq __PACKAGE__;
    utf8::encode($password);
    die 'password too long, possible DOS attack' if length($password) > 200;
    my $salt = _salt;
    my $hash = Crypt::ScryptKDF::scrypt_b64($password, $salt);
    return ALGO_VERSION . "*$salt*$hash";
}

=head2 checkpw($string, $hashed) 

Returns true if the password matches when hashed.  False otherwise.

=cut

# This is a dispatch table for algorithm -> checking routines.  It is here so
# we can safely add new algorithms in backwards-compatible ways.  When adding a
# new algorithm, add the check here in algo_num => sub form.  true means passes,
# false means fails.

my $passwd_check = {
    1 => sub {
        my ($pwhash, $password) = @_;
        return Mojo::Util::secure_compare($pwhash->{hash}, Crypt::ScryptKDF::scrypt_b64($password, $pwhash->{salt}));
    },
};

sub checkpw {
    my ($password, $hashstring) = @_;
    return if length($password) > 200;    # fail if too long
    return unless defined $password;      # always fail when no password
    return _legacy_pwcheck($password, $hashstring)
        unless $hashstring =~ /^\d+\*/;
    utf8::encode($password);
    my $pwhash = _pwstring_to_hashref($hashstring);
    return $passwd_check->{$pwhash->{version}}($pwhash, $password);
}

# private functions

sub _pwstring_to_hashref {
    my $string = shift;
    my ($ver, $salt, $hash) = split /\*/, $string;
    return {
        version => $ver,
        salt    => $salt,
        hash    => $hash
    };
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

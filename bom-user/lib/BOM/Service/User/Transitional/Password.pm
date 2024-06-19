package BOM::Service::User::Transitional::Password;
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

=head2 hashpw

This subroutine takes a password as input, encodes it to UTF-8, and returns a hashed password string. The password is hashed using the Scrypt key derivation function. The hashed password string includes the algorithm version and the hashed password, separated by a '*'. If the length of the password is more than 200 characters, the subroutine dies with an error message indicating a possible DOS attack.

=over 4

=item * Input: String (password)

=item * Return: String (hashed password string in the format 'ALGO_VERSION*hashed_password')

=back

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

=head2 checkpw

Takes a password and a hashed password string. It checks if the password length is not more than 200 characters and if the password is defined. It then verifies the password against the hashed password string using the appropriate password checking algorithm based on the version stored in the hashed password string.

=over 4

=item * Input: String (password), String (hashstring)

=item * Return: Boolean (true if password matches, false otherwise)

=back

=cut

sub checkpw {
    my ($password, $hashstring) = @_;
    return if length($password) > 200;    # fail if too long
    return unless defined $password;      # always fail when no password

    my $pwhash = _pwstring_to_hashref($hashstring);
    return $passwd_check->{$pwhash->{version}}($pwhash, $password);
}

# private functions

=head2 _pwstring_to_hashref

Takes a password string and converts it into a hash reference. The password string is expected to start with a version number followed by a '*', and then the hashed password. The function supports version 0 (default), 1, and 2. For version 1, the hashed password string is split into salt and hash. For version 2, the hashed password string is directly assigned to the hash. If the version is not supported, the function dies with an error message.

=over 4

=item * Input: String (password string)

=item * Return: HashRef (hash reference with keys 'version', 'hash', and 'salt')

=back

=cut

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

=head2 _legacy_pwcheck

This subroutine checks a given password against a hashed password. It supports three types of hashed passwords:

1. Hashed passwords that start with '6$'. These are compared using the 'crypt' function and 'Mojo::Util::secure_compare'.
2. Legacy SHA256 hashed passwords with no salt. These are 64 characters long and are compared using a legacy SHA256 function and 'Mojo::Util::secure_compare'.
3. Legacy 'crypt' hashed passwords for cashier lock passwords. These do not start with '6$' and are not 64 characters long. The first two characters of the hash are used as the salt for the 'crypt' function.

=over 4

=item * Input: String (password), String (hashed password)

=item * Return: Boolean (true if the password matches the hash, false otherwise)

=back

=cut

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

=head2 _legacy_sha256

This subroutine takes a password as input and returns its SHA256 hash. It is used for handling legacy SHA256 hashed passwords with no salt. If the password is not defined, it returns undef.

=over 4

=item * Input: String (password)

=item * Return: String (SHA256 hash of the password) or undef if the password is not defined

=back

=cut

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

=head2 update_dx_trading_password

This subroutine updates the Deriv X trading password of a user. It first checks if the trading password is provided. If not, it dies with a 'PasswordRequired' message. Then, it hashes the trading password using the 'hashpw' subroutine from the 'BOM::Service::User::Transitional::Password' module.

Next, it updates the user's Deriv X trading password in the database by running a database operation that calls the 'update_trading_password' method from the 'users' table. The hashed password is passed to this method.

Finally, it returns the updated user object.

=over 4

=item * Input: User object, String (trading_password)

=item * Return: Updated User object

=back

=cut

sub update_dx_trading_password {
    my ($user, $trading_password) = @_;

    die 'PasswordRequired' unless $trading_password;

    my $hash_pw = hashpw($trading_password);

    $user->{dx_trading_password} = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select dx_trading_password from users.update_trading_password(?, ?, ?)', undef, $user->{id}, undef, $hash_pw);
        });

    return $user;
}

=head2 update_trading_password

Takes a user object and a trading password. It hashes the trading password, updates the user's trading password in the database, and returns the updated user object.

=over 4

=item * Input: User object, String (trading_password)

=item * Return: Updated User object

=back

=cut

sub update_trading_password {
    my ($user, $trading_password) = @_;

    die 'PasswordRequired' unless $trading_password;

    my $hash_pw = hashpw($trading_password);

    $user->{trading_password} = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array('select trading_password from users.update_trading_password(?, ?, ?)', undef, $user->{id}, $hash_pw, undef);
        });

    return $user;
}

1;

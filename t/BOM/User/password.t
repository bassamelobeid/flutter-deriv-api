use strict;
use warnings;
use utf8;
binmode STDOUT, ':utf8';

use Test::More tests => 21;
use Test::Warnings;
use BOM::User::Password;
use Digest::SHA;
use Crypt::ScryptKDF;

# crypted passwords -- LEGACY CASHIER LOCKING PASSWORDS
ok(BOM::User::Password::checkpw('foo',    crypt('foo',    '12')), 'crypt foo, correct');
ok(BOM::User::Password::checkpw('secret', crypt('secret', 'X/')), 'crypt secret correct');
ok(!BOM::User::Password::checkpw('foo',    crypt('bar',    '12')), 'crypt foo, incorrect');
ok(!BOM::User::Password::checkpw('secret', crypt('foobar', 'X/')), 'crypt secret, incorrect');

# sha256 unsalted passwords -- LEGACY ACCOUNT PASSWORDS
ok(BOM::User::Password::checkpw('foo',    Digest::SHA::sha256_hex('foo')),    'sha foo correct');
ok(BOM::User::Password::checkpw('secret', Digest::SHA::sha256_hex('secret')), 'sha secret correct');
ok(!BOM::User::Password::checkpw('foo',    Digest::SHA::sha256_hex('bar')),    'sha foo incorrect');
ok(!BOM::User::Password::checkpw('secret', Digest::SHA::sha256_hex('foobar')), 'sha secret incorrect');

# generation 1 passwords -- Current account and cashier locking passwords
my $salt       = 'GhfeHD0H2YWmtny3';
my $foohash    = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('foo', $salt);
my $secrethash = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('secret', $salt);
ok(BOM::User::Password::checkpw('foo',    $foohash),    'ver 1, foo, correct');
ok(BOM::User::Password::checkpw('secret', $secrethash), 'ver 1, secret, correct');
ok(!BOM::User::Password::checkpw('foo',    $secrethash), 'ver1, foo, incorrect');
ok(!BOM::User::Password::checkpw('secret', $foohash),    'ver 1, secret, correct');

# Password hash and check round trips
ok(BOM::User::Password::checkpw('foo', BOM::User::Password::hashpw('foo')), 'hash password round trip, foo, correct');

ok(BOM::User::Password::checkpw('secret', BOM::User::Password::hashpw('secret')), 'hash password round trip, secret, correct');

ok(!BOM::User::Password::checkpw('foo', BOM::User::Password::hashpw('bar')), 'hash password round trip, foo, incorrect');

ok(!BOM::User::Password::checkpw('secret', BOM::User::Password::hashpw('foo')), 'hash password round trip, secret, incorrect');

ok(BOM::User::Password::checkpw('São Paulo', BOM::User::Password::hashpw('São Paulo')), 'hash password round trip, "São Paulo", correct');

ok(!BOM::User::Password::checkpw('São Paulo', BOM::User::Password::hashpw('Sao Paulo')),
    'hash password round trip, "São Paulo", incorrect');
ok(
    BOM::User::Password::checkpw(
        'ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ',
        BOM::User::Password::hashpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ')
    ),
    'hash password round trip, unicode, correct'
);
ok(!BOM::User::Password::checkpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ', BOM::User::Password::hashpw('São Paulo')),
    'hash password round trip, unicode, incorrect');


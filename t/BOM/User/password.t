use strict;
use warnings;
use utf8;
binmode STDOUT, ':utf8';

use Test::More tests => 25;
use Test::Warnings;
use Test::Exception;
use BOM::User::Password;
use Digest::SHA;
use Crypt::ScryptKDF;

# crypted passwords -- LEGACY CASHIER LOCKING PASSWORDS
ok(BOM::User::Password::checkpw('foo',     crypt('foo',    '12')), 'crypt foo, correct');
ok(BOM::User::Password::checkpw('secret',  crypt('secret', 'X/')), 'crypt secret correct');
ok(!BOM::User::Password::checkpw('foo',    crypt('bar',    '12')), 'crypt foo, incorrect');
ok(!BOM::User::Password::checkpw('secret', crypt('foobar', 'X/')), 'crypt secret, incorrect');

# sha256 unsalted passwords -- LEGACY ACCOUNT PASSWORDS
ok(BOM::User::Password::checkpw('foo',     Digest::SHA::sha256_hex('foo')),    'sha foo correct');
ok(BOM::User::Password::checkpw('secret',  Digest::SHA::sha256_hex('secret')), 'sha secret correct');
ok(!BOM::User::Password::checkpw('foo',    Digest::SHA::sha256_hex('bar')),    'sha foo incorrect');
ok(!BOM::User::Password::checkpw('secret', Digest::SHA::sha256_hex('foobar')), 'sha secret incorrect');

# generation 1 passwords -- Current account and cashier locking passwords
my $salt       = 'GhfeHD0H2YWmtny3';
my $foohash    = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('foo',    $salt);
my $secrethash = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('secret', $salt);
ok(BOM::User::Password::checkpw('foo',     $foohash),    'ver 1, foo, correct');
ok(BOM::User::Password::checkpw('secret',  $secrethash), 'ver 1, secret, correct');
ok(!BOM::User::Password::checkpw('foo',    $secrethash), 'ver1, foo, incorrect');
ok(!BOM::User::Password::checkpw('secret', $foohash),    'ver 1, secret, correct');

# Password hash and check round trips
ok(BOM::User::Password::checkpw('foo', BOM::User::Password::hashpw('foo')), 'hash password round trip, foo, correct');

ok(BOM::User::Password::checkpw('secret', BOM::User::Password::hashpw('secret')), 'hash password round trip, secret, correct');

ok(!BOM::User::Password::checkpw('foo', BOM::User::Password::hashpw('bar')), 'hash password round trip, foo, incorrect');

ok(!BOM::User::Password::checkpw('secret', BOM::User::Password::hashpw('foo')), 'hash password round trip, secret, incorrect');

ok(BOM::User::Password::checkpw('São Paulo', BOM::User::Password::hashpw('São Paulo')), 'hash password round trip, "São Paulo", correct');

ok(!BOM::User::Password::checkpw('São Paulo', BOM::User::Password::hashpw('Sao Paulo')), 'hash password round trip, "São Paulo", incorrect');
ok(BOM::User::Password::checkpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ', BOM::User::Password::hashpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ')),
    'hash password round trip, unicode, correct');
ok(!BOM::User::Password::checkpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ', BOM::User::Password::hashpw('São Paulo')), 'hash password round trip, unicode, incorrect');

# test different version of password
ok(BOM::User::Password::checkpw('São Paulo', '1*fUpmNZvYEKa8QkXu*H3qq0QnooATqGna6Px6q/3rqAZZAV6GYqx1ISivQ3t0='),
    'version 1 of password can be checked');
ok(BOM::User::Password::checkpw('São Paulo', '2*SCRYPT:16384:8:1:lkUvbSyxJduZAvgseqZvyg==:pks9+s4GDdbsZklk5BNPuVbOlM+rzsXWh2WDCxhFeJc='),
    'version 2 of password can be checked');
like(BOM::User::Password::hashpw('São Paulo'), qr/^2\*/, 'We are creating version 2 password now');
throws_ok { BOM::User::Password::checkpw("hello", "3*hello") } qr/Don't support the format of password/, 'We do not support version 3';


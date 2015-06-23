use Test::More tests => 20;
use BOM::System::Password;
use Digest::SHA;
use Crypt::ScryptKDF;

## Tests for checking passwords

# crypted passwords -- LEGACY CASHIER LOCKING PASSWORDS

ok(BOM::System::Password::checkpw('foo',    crypt('foo',    '12')), 'crypt foo, correct');
ok(BOM::System::Password::checkpw('secret', crypt('secret', 'X/')), 'crypt secret correct');
ok(!BOM::System::Password::checkpw('foo',    crypt('bar',    '12')), 'crypt foo, incorrect');
ok(!BOM::System::Password::checkpw('secret', crypt('foobar', 'X/')), 'crypt secret, incorrect');

# sha256 unsalted passwords -- LEGACY ACCOUNT PASSWORDS

ok(BOM::System::Password::checkpw('foo',    Digest::SHA::sha256_hex('foo')),    'sha foo correct');
ok(BOM::System::Password::checkpw('secret', Digest::SHA::sha256_hex('secret')), 'sha secret correct');
ok(!BOM::System::Password::checkpw('foo',    Digest::SHA::sha256_hex('bar')),    'sha foo incorrect');
ok(!BOM::System::Password::checkpw('secret', Digest::SHA::sha256_hex('foobar')), 'sha secret incorrect');

# generation 1 passwords -- Current account and cashier locking passwords
my $salt = 'GhfeHD0H2YWmtny3';
$foohash    = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('foo',    $salt);
$secrethash = "1*$salt*" . Crypt::ScryptKDF::scrypt_b64('secret', $salt);
ok(BOM::System::Password::checkpw('foo',    $foohash),    'ver 1, foo, correct');
ok(BOM::System::Password::checkpw('secret', $secrethash), 'ver 1, secret, correct');
ok(!BOM::System::Password::checkpw('foo',    $secrethash), 'ver1, foo, incorrect');
ok(!BOM::System::Password::checkpw('secret', $foohash),    'ver 1, secret, correct');

# Password hash and check round trips
ok(BOM::System::Password::checkpw('foo', BOM::System::Password::hashpw('foo')), 'hash password round trip, foo, correct');

ok(BOM::System::Password::checkpw('secret', BOM::System::Password::hashpw('secret')), 'hash password round trip, secret, correct');

ok(!BOM::System::Password::checkpw('foo', BOM::System::Password::hashpw('bar')), 'hash password round trip, foo, incorrect');

ok(!BOM::System::Password::checkpw('secret', BOM::System::Password::hashpw('foo')), 'hash password round trip, secret, incorrect');

ok(BOM::System::Password::checkpw('São Paulo', BOM::System::Password::hashpw('São Paulo')), 'hash password round trip, "São Paulo", correct');

ok(!BOM::System::Password::checkpw('São Paulo', BOM::System::Password::hashpw('Sao Paulo')), 'hash password round trip, "São Paulo", incorrect');
ok(
    BOM::System::Password::checkpw(
        'ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ',
        BOM::System::Password::hashpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ')
    ),
    'hash password round trip, unicode, correct'
);
ok(!BOM::System::Password::checkpw('ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ', BOM::System::Password::hashpw('São Paulo')),
    'hash password round trip, unicode, incorrect');


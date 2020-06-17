use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::MT5::User::Async;

# undef means it should die
my %mock_data = (
    'MTR45454545'  => 'real',
    'MTD12345678'  => 'demo',
    'MT0000008'    => 'real',
    'ASDF12345678' => undef,
    'MTDDDDDDD'    => undef
);

subtest 'MT5 Account type' => sub {
    for (keys %mock_data) {
        my $result = $mock_data{$_};

        is(BOM::MT5::User::Async::get_account_type($_), $result, $_ . ' is ' . $result) if defined $result;
        dies_ok(sub { BOM::MT5::User::Async::get_account_type($_) }, $_ . ' is not expected') unless defined $result;
    }
};

done_testing;

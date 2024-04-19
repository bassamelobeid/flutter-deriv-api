#!perl

use utf8;
binmode STDOUT, ':encoding(UTF-8)';

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::User::Utility;

my $mocked_thirdparty = Test::MockModule->new('BOM::Config');
$mocked_thirdparty->mock(
    'third_party',
    sub {
        return {'customerio' => {'hash_key' => 'some_key'}};
    });

subtest 'checksum generate' => sub {
    my @expected = ({
            'loginid'  => '228',
            'email'    => 'test1@test.com',
            'checksum' => '4c0e3c144e9bbcc25a4793ba48fb6ab0e79802da',
        },
        {
            'loginid'  => 'CR10000',
            'email'    => 'test2@test.com',
            'checksum' => 'e6fc2ade00bf4fe4ae79d7954e1fd351952687b7',
        });
    foreach my $ex (@expected) {
        my $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($ex->{'loginid'}, $ex->{'email'});
        is $checksum, $ex->{'checksum'}, "Checksum matches for user " . $ex->{'loginid'};
    }
};

done_testing();

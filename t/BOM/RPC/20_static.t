use strict;
use warnings;

use utf8;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'residence_list' => sub {
    my $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    my ($cn) = grep { $_->{value} eq 'cn' } @$result;
    is_deeply(
        $cn,
        {
            'value'     => 'cn',
            'text'      => "China",
            'phone_idd' => '86'
        },
        'cn is correct'
    );
};

subtest 'states_list' => sub {
    my $result = $c->call_ok(
        'states_list',
        {
            language => 'EN',
            args     => {states_list => 'cn'}})->has_no_system_error->result;
    my ($sh) = grep { $_->{text} eq 'Shanghai' } @$result;
    is_deeply(
        $sh,
        {
            'value' => '31',
            'text'  => "Shanghai",
        },
        'Shanghai is correct'
    );
};

done_testing();

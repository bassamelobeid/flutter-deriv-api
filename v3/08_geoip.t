use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use Encode;

subtest 'country information is returned in website_status' => sub {
    for my $country (qw(my jp ru cr)) {
        my $t = build_wsapi_test(undef, {
            'CF-IPCOUNTRY' => $country,
        });
        $t = $t->send_ok({json => {website_status => 1}})->message_ok;
        my $res = decode_json($t->message->[1]);
        is($res->{website_status}{clients_country}, $country, 'have correct country for ' . $country);
        $t->finish_ok;
    }
    done_testing;
};
subtest 'country code Malaysia' => sub {
    my $t = build_wsapi_test(undef, {
        'CF-IPCOUNTRY' => 'my',
    });
    $t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
    my $res = decode_json($t->message->[1]);
    cmp_deeply($res->{payout_currencies}, bag(qw(USD EUR GBP AUD)), 'payout currencies are correct') or note explain $res;
    $t->finish_ok;
    done_testing;
};
subtest 'country code Japan' => sub {
    my $t = build_wsapi_test(undef, {
        'CF-IPCOUNTRY' => 'jp',
    });
    $t = $t->send_ok({json => {payout_currencies => 1}})->message_ok;
    my $res = decode_json($t->message->[1]);
    cmp_deeply($res->{payout_currencies}, bag(qw(JPY)), 'payout currencies are correct') or note explain $res;
    $t->finish_ok;
    done_testing;
};

done_testing();

use strict;
use warnings;
use Test::MockTime::HiRes;
use Guard;
use JSON;

use Test::More (tests => 2);
use Test::Warnings;
use Test::Exception;
use Test::Warn;
use Test::MockModule;

use BOM::RPC::v3::Utility;
use BOM::Platform::Account::Virtual;

subtest 'get_real_acc_opening_type' => sub {
    my $type_map = {
        'real'        => ['id', 'gb', 'nl'],
        'maltainvest' => ['de'],
        'japan'       => ['jp'],
        'restricted' => ['us', 'my'],
    };

    foreach my $acc_type (keys %$type_map) {
        foreach my $c (@{$type_map->{$acc_type}}) {
            my $vr_client;
            lives_ok {
                my $acc = create_vr_acc({
                    email           => 'shuwnyuan-test-' . $c . '@binary.com',
                    client_password => 'foobar',
                    residence       => ($acc_type eq 'restricted') ? 'id' : $c,
                });
                $vr_client = $acc->{client};
                $vr_client->residence($c);
            }
            'create vr acc';

            my $type_result;
            $type_result = $acc_type if ($acc_type ne 'restricted');
            is(BOM::RPC::v3::Utility::get_real_acc_opening_type({from_client => $vr_client}), $type_result, "$c: acc type - " . ($type_result // ''));
        }
    }
};

sub create_vr_acc {
    my $args = shift;
    return BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
            }});
}

use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Array::Utils qw/array_minus/;

use LandingCompany::Registry;
use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->connect_clientdb' => sub {
    subtest 'does not accept virtual broker codes' => sub {
        my @all_real_broker_codes = LandingCompany::Registry->all_real_broker_codes();
        my @all_bloker_codes      = LandingCompany::Registry->all_broker_codes();

        my @virtual_broker_codes = array_minus(@all_bloker_codes, @all_real_broker_codes);

        ok scalar(@virtual_broker_codes) > 0, 'there is at least one virtual broker code';

        for my $bc (@virtual_broker_codes) {
            my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => $bc);
            my $exc             = exception { $auto_reject_obj->client_dbic(); };
            like $exc, qr/^Invalid broker code./, "broker code $bc is not valid";
        }
    };
};

done_testing;

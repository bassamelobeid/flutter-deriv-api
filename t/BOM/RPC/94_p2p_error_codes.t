use strict;
use warnings;
use Test::More;
use B::Deparse;

use BOM::User::Client;
use BOM::RPC::v3::P2P;

Test::Warnings::allow_warnings(1);

# Ensures that P2P errors thrown in bom-user have corresponding definitions in bom-rpc.
# B::Deparse creates warnings about "catch" blocks, and they aren't covered in this test.

# Extra subs in BOM::User::Client to check. Ones with 'p2p' in the name are included by default.
my @subs = qw(
    _validate_advert_amounts
    _order_ownership_type
    _client_buy_confirm
    _advertiser_buy_confirm
    _client_sell_confirm
    _advertiser_sell_confirm
);

my $deparse = B::Deparse->new();
no strict 'refs';

for my $name (keys %{'BOM::User::Client::'}) {
    my $sub = BOM::User::Client->can($name);
    next unless $sub && $name =~ /p2p/ or grep { /^$name$/ } @subs;
    my $code        = $deparse->coderef2text($sub);
    my @error_codes = ($code =~ /\{\'error_code\', \'(.+?)\'/g);
    ok $BOM::RPC::v3::P2P::ERROR_MAP{$_}, "$_ error code (in $name) is defined" for @error_codes;
}

done_testing();

use Test::More tests => 1;
use strict;
use warnings;

if (my $r =
    `git grep BOM:: | grep -v '^t/' | grep -v -e BOM::Test -e BOM::WebSocketAPI -e BOM::RPC::v3::Utility -e BOM::Platform::Context::I18N -e BOM::System::Config -e BOM::Feed -e BOM::System::RedisReplicated -e BOM::Platform::Token::Verification -e BOM::Database::Model::OAuth -e BOM::Database::Rose::DB -e BOM::Market::Underlying -e BOM::RPC::v3::Contract -e BOM::RPC::v3::Japan::Contract`
    )
{
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}

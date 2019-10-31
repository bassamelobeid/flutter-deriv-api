use strict;
use warnings;

use Test::Most;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;

my $proposal_param = {
    "proposal"      => 1,
    "subscribe"     => 1,
    "amount"        => "10",
    "basis"         => "payout",
    "contract_type" => "PUT",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "5",
    "duration_unit" => "h",
    "barrier"       => "+13.12"
};

is(Binary::WebSocketAPI::v3::Wrapper::Pricer::_skip_streaming($proposal_param), undef, "Streams non ATM PUT");
$proposal_param->{contract_type} = 'ONETOUCH';
is(Binary::WebSocketAPI::v3::Wrapper::Pricer::_skip_streaming($proposal_param), undef, "Streams ONEOTUCH");
$proposal_param->{contract_type} = 'RANGE';
$proposal_param->{barrier2}      = '-13.12';
is(Binary::WebSocketAPI::v3::Wrapper::Pricer::_skip_streaming($proposal_param), undef, "Streams RANGE ");
$proposal_param->{contract_type} = 'EXPIRYMISS';
$proposal_param->{barrier2}      = '-13.12';
is(Binary::WebSocketAPI::v3::Wrapper::Pricer::_skip_streaming($proposal_param), undef, "Streams EXPIRYMISS");

$proposal_param->{contract_type} = 'CALL';
delete $proposal_param->{barrier};
delete $proposal_param->{barrier2};
is(Binary::WebSocketAPI::v3::Wrapper::Pricer::_skip_streaming($proposal_param), 1, "Do not stream ATM synthetic_index");

done_testing();

#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open                     qw[ :encoding(UTF-8) ];
use lib                      qw(/home/git/regentmarkets/bom-backoffice);
use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use Syntax::Keyword::Try;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use BOM::Backoffice::Request          qw(request);
use BOM::Backoffice::CallputspreadBarrierMultiplier;

BOM::Backoffice::Sysinit::init();
my $r = request();

if ($r->param('create_callputspread_barrier_multiplier')) {
    my $args = {
        barrier_type                                     => $r->param('barrier_type'),
        forex_callputspread_barrier_multiplier           => $r->param('forex_callputspread_barrier_multiplier'),
        synthetic_index_callputspread_barrier_multiplier => $r->param('synthetic_index_callputspread_barrier_multiplier'),
        commodities_callputspread_barrier_multiplier     => $r->param('commodities_callputspread_barrier_multiplier')};

    my $validated_arg = BOM::Backoffice::CallputspreadBarrierMultiplier::validate_params($args);

    if (defined $validated_arg->{error}) {
        return print encode_json_utf8({error => $validated_arg->{error}});
    }

    my $result = BOM::Backoffice::CallputspreadBarrierMultiplier::save($validated_arg);

    my $output;
    if ($result->{success}) {
        $output = {success => 1};
    } else {
        $output = {error => $result->{error}};
    }

    print encode_json_utf8($output);
}

#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use f_brokerincludeall;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::CFDS::DataSource::PlatformConfig;

BOM::Backoffice::Sysinit::init();

use constant GENERAL_DB_ERROR_CODE => 'DB_ERROR';

my $r                   = request();
my $action_identifier   = $r->param('action_identifier')   // '';
my $data_identifier_key = $r->param('data_identifier_key') // '';
my $payload_json        = $r->param('payload')             // '{}';
my $payload             = decode_json_utf8($payload_json);

if ($action_identifier eq 'spread_update') {
    try {
        BOM::CFDS::DataSource::PlatformConfig->new()->update_internal_spread_config({
                symbol_id    => $payload->{id},
                spread_value => $payload->{spread_value},
                platform     => $payload->{cfd_platform},
                asset_class  => $payload->{asset_class}});
    } catch ($e) {
        print encode_json_utf8({error => {error_code => GENERAL_DB_ERROR_CODE, error_message => $e}});
        exit;
    }

    print encode_json_utf8({status => 'success', message => 'Updated successfully'});
}

if ($action_identifier eq 'spread_consistency_sync_update') {
    # API call needed
    print encode_json_utf8({error => {error_code => '500', error_message => 'Not implemented yet'}});
}

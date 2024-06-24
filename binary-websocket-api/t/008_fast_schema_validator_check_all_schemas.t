use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::FastSchemaValidator;
use Data::Dumper;
use Path::Tiny;

use JSON::MaybeUTF8 qw(:v1);

my $schema_dir = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

#This list should generally only get shorter unless there is a good reason. Please either add support to the FastSchemaValidator
#for new constructs that you are using, or stick to supported checks. If this test is causing annoyance, please contact Tristam.
my $unsupported_schemas = {
    'api_token/send.json'                              => 1,
    'app_markup_details/send.json'                     => 1,
    'app_register/send.json'                           => 1,
    'app_update/send.json'                             => 1,
    'authorize/send.json'                              => 1,
    'buy_contract_for_multiple_accounts/receive.json'  => 1,
    'cashier/receive.json'                             => 1,
    'copy_start/send.json'                             => 1,
    'exchange_rates/receive.json'                      => 1,
    'forget_all/send.json'                             => 1,
    'landing_company/receive.json'                     => 1,
    'mt5_login_list/receive.json'                      => 1,
    'mt5_new_account/send.json'                        => 1,
    'new_account_maltainvest/send.json'                => 1,
    'new_account_real/send.json'                       => 1,
    'new_account_virtual/send.json'                    => 1,
    'notifications_list/receive.json'                  => 1,
    'p2p_advert_create/send.json'                      => 1,
    'p2p_advert_info/receive.json'                     => 1,
    'p2p_advert_list/receive.json'                     => 1,
    'p2p_advert_update/send.json'                      => 1,
    'p2p_advertiser_info/receive.json'                 => 1,
    'p2p_advertiser_payment_methods/send.json'         => 1,
    'p2p_advertiser_relations/send.json'               => 1,
    'p2p_country_list/receive.json'                    => 1,
    'p2p_order_create/send.json'                       => 1,
    'p2p_order_info/receive.json'                      => 1,
    'p2p_order_list/receive.json'                      => 1,
    'p2p_order_review/receive.json'                    => 1,
    'p2p_order_review/send.json'                       => 1,
    'p2p_settings/receive.json'                        => 1,
    'passkeys_login/receive.json'                      => 1,
    'passkeys_register/send.json'                      => 1,
    'passkeys_register_options/receive.json'           => 1,
    'paymentagent_create/send.json'                    => 1,
    'paymentagent_details/receive.json'                => 1,
    'paymentagent_withdraw_justification/send.json'    => 1,
    'portfolio/send.json'                              => 1,
    'profit_table/send.json'                           => 1,
    'proposal_open_contract/receive.json'              => 1,
    'sell_contract_for_multiple_accounts/receive.json' => 1,
    'service_token/send.json'                          => 1,
    'set_settings/send.json'                           => 1,
    'ticks/send.json'                                  => 1,
    'trading_platform_asset_listing/receive.json'      => 1,
    'trading_platform_asset_listing/send.json'         => 1,
    'trading_platform_deposit/receive.json'            => 1,
    'trading_platform_deposit/send.json'               => 1,
    'trading_platform_leverage/receive.json'           => 1,
    'trading_platform_password_change/send.json'       => 1,
    'trading_platform_password_reset/send.json'        => 1,
    'trading_platform_status/receive.json'             => 1,
    'trading_platform_withdrawal/send.json'            => 1,
    'transaction/receive.json'                         => 1,
    'verify_email/send.json'                           => 1,
    'verify_email_cellxpert/send.json'                 => 1,
    'website_config/receive.json'                      => 1,
    'website_status/receive.json'                      => 1,
};

sub prepare_from_file_error {
    my ($schema_path) = @_;
    my ($fast_schema, $error_str) = Binary::WebSocketAPI::FastSchemaValidator::prepare_fast_validate(decode_json_utf8($schema_path->slurp));
    #print "Loading $schema_path -> $error_str -> ".Dumper($fast_schema);
    return $error_str;
}

sub get_schemas_to_check {
    my @ret;
    for my $p (path($schema_dir)->children) {
        push @ret, $p->children(qr/(receive|send)\.json$/);

    }
    return @ret;
}

my $total                         = 0;
my $works                         = 0;
my %unsupported_schema_full_paths = map { $schema_dir . $_ => 1 } keys %$unsupported_schemas;

for my $schema_path (sort (get_schemas_to_check())) {
    $total++;
    my $res = prepare_from_file_error($schema_path);
    $works++ if $res eq '';

    if (defined($unsupported_schema_full_paths{$schema_path})) {
        isnt $res, '',
            "Expected $schema_path to be unsupported by FastSchemaValidator, if this test fails, please remove $schema_path from the list in 008_fast_schema_validator_check_all_schemas.t as it appears to be supported now.";
    } else {
        is $res, '',
            "Expected $schema_path to be supported by FastSchemaValidator (please see comments in 008_fast_schema_validator_check_all_schemas.t if this test fails), got error.";
    }

    print "CHECKED: $schema_path " . ($res eq '' ? "OK" : "NotSupported") . " $res\n";
}

print "Parsed $works out of $total\n";

done_testing();


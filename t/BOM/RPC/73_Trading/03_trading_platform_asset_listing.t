use Test::Most;
use Test::MockModule;
use Test::MockObject;
use BOM::RPC::v3::Trading;

use JSON::MaybeUTF8 qw(:v1);

subtest 'smoke' => sub {

    my $mock_redis_mt5_user = Test::MockModule->new('RedisDB');
    my $fake_asset          = {
        symbol         => 'bukazoid',           # symbol is required as it is referenced in the implementation
        asset_data_key => 'asset_data_value',
    };
    $mock_redis_mt5_user->mock(
        'get',
        sub {
            my ($self, $input_key) = @_;
            my $group_key  = 'asset_listing::mt5::srv::acc_t::lc::mrk_t::acc_st::acc_sc';
            my $symbol_key = 'mt5::sym';
            if ($input_key eq $group_key) {
                return encode_json_utf8([$symbol_key]);
            }
            if ($input_key eq $symbol_key) {
                return encode_json_utf8($fake_asset);
            }
            die "Unexpected input key '$input_key'";
        });

    my $normalized_args = {
        # we have to put MT5 here as it is used to instantiate specific TradingPlatform
        platform              => ['mt5'],
        server                => ['srv'],
        account_type          => ['acc_t'],
        landing_company_short => ['lc'],
        market_type           => ['mrk_t'],
        sub_account_type      => ['acc_st'],
        sub_account_category  => ['acc_sc'],
    };

    my $response = BOM::RPC::v3::Trading::trading_platform_asset_listing({args => $normalized_args});
    is_deeply $response, {'mt5' => {'assets' => [$fake_asset]}}, 'send_data matches';
};

done_testing();

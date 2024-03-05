use strict;
use warnings;

use Test::More;
use BOM::Config;

# validate the method can work and return non-empty config
# those configs are too big and dynamic,
# maybe we can pick a few config keys to test in future

ok BOM::Config::node(),          'node';
ok BOM::Config::aes_keys(),      'aes_keys';
ok BOM::Config::randsrv(),       'randsrv';
ok BOM::Config::s3(),            's3';
ok BOM::Config::feed_rpc(),      'feed_rpc';
ok BOM::Config::third_party(),   'third_party';
ok BOM::Config::backoffice(),    'backoffice';
ok BOM::Config::quants(),        'quants';
ok BOM::Config::payment_agent(), 'payment_agent';
ok BOM::Config::domain(),        'domain';
ok BOM::Config::brand(),         'brand';
ok BOM::Config::sanction_file(), 'sanction_file';

ok BOM::Config::redis_replicated_config(),          'redis_replicated_config';
ok BOM::Config::redis_pricer_config(),              'redis_pricer_config';
ok BOM::Config::redis_pricer_subscription_config(), 'redis_pricer_subscription_config';
ok BOM::Config::redis_pricer_shared_config(),       'redis_pricer_shared_config';
ok BOM::Config::redis_exchangerates_config(),       'redis_exchangerates_config';
ok BOM::Config::redis_feed_config(),                'redis_feed_config';
ok BOM::Config::redis_mt5_user_config(),            'redis_mt5_user_config';
ok BOM::Config::redis_events_config(),              'redis_events_config';
ok BOM::Config::redis_rpc_config(),                 'redis_rpc_config';
ok BOM::Config::redis_transaction_config(),         'redis_transaction_config';
ok BOM::Config::redis_limit_settings(),             'redis_limit_settings';
ok BOM::Config::redis_auth_config(),                'redis_auth_config';
ok BOM::Config::redis_expiryq_config(),             'redis_expiryq_config';
ok BOM::Config::redis_p2p_config(),                 'redis_p2p_config';
ok BOM::Config::redis_ws_config(),                  'redis_ws_config';
ok BOM::Config::mt5_user_rights(),                  'mt5_user_rights';
ok BOM::Config::mt5_account_types(),                'mt5_account_types';
ok BOM::Config::mt5_webapi_config(),                'mt5_webapi_config';
ok BOM::Config::redis_payment_config(),             'redis_payment_config';
ok BOM::Config::paymentapi_config(),                'paymentapi_config';
ok !BOM::Config::on_production(),                   'not on_production';
ok BOM::Config::cashier_env(),                      'cashier_env';
ok BOM::Config::cashier_config(),                   'cashier_config';
ok BOM::Config::on_qa() || BOM::Config::on_ci(),    'on_qa or on_ci';
ok BOM::Config::crypto_internal_api(),              'crypto_internal_api';

done_testing();

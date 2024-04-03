package BOM::Config;

use strict;
use warnings;

=head1 NAME

C<BOM::Config> - Configuration management for our BOM modules.

=head1 SYNOPSIS

   use BOM::Config;

   my $config = BOM::Config::third_party()->{customerio};

=head1 DESCRIPTION

This module provides a config loader for all our local and production configurations.
The configuration information for the main e-commerce platform and pricing is stored as YAML
which in turn is read by this module, providing L<state> based serialized objects.

B<NOTE>: The YAMLs are rendered by binary_config cookbook in chef

=cut

use feature "state";
use YAML::XS;
use Brands;

=head2 node

Get I<chef> node information

Example:

    my $config = BOM::Config::node();
    my $env    = $config->{node}->{environment};

Returns a hashref of configuration information for the node a service is running on.

=cut

sub node {
    state $config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    return $config;
}

=head2 feed_listener

Get information about the feed listener

Example:

    my $config = BOM::Config::feed_listener();
    my $user   = $config->{idata}->{forex_user};

Returns a hashref of configuration information for the feed_listener service.

B<Note>: This configuration will throw an error for machines where feed is not set up.

=cut

sub feed_listener {
    state $config = YAML::XS::LoadFile('/etc/rmg/feed_listener.yml');
    return $config;
}

=head2 aes_keys

Get information about AES keys

Example:

    $app->secrets([BOM::Config::aes_keys()->{web_secret}{1}]);

Returns a hashref of configuration information for our systems app secrets.

=cut

sub aes_keys {
    state $config = YAML::XS::LoadFile('/etc/rmg/aes_keys.yml');
    return $config;
}

=head2 randsrv

Get information about Random Server

Example:

    my $config = BOM::Config::randsrv();
    my $server = $config->{rand_server}->{fqdn};

Returns a hashref of IP, port and password for the random server.

=cut

sub randsrv {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_RAND} // '/etc/rmg/randsrv.yml');
    return $config;
}

=head2 third_party

Get information about third party credentials 

Example:

    my $config     = BOM::Config::third_party();
    my $myaff_user = $config->{myaffiliates}->{user};

Returns a hashref of all credentials to the third party systems we have integrated with.

B<NOTE>: All credentials should be masked in non-production machines

=cut

sub third_party {
    state $config = YAML::XS::LoadFile('/etc/rmg/third_party.yml');
    return $config;
}

=head2 service_social_login

Get information about social login service config info
Example:
    my $config     = BOM::Config::service_social_login();
    my $host = $config->{host};
Returns a hashref of all config info of social login service.

=cut

sub service_social_login {
    state $config = YAML::XS::LoadFile('/etc/rmg/microservice_social_login.yml');
    return $config;
}

=head2 backoffice

Get information about our Backoffice system

Example:

    my $config  = BOM::Config::backoffice();
    my $bo_temp = $config->{directory}->{tmp};

Returns a hashref of all configuration properties related to BO.

=cut

sub backoffice {
    state $config = YAML::XS::LoadFile('/etc/rmg/backoffice.yml');
    return $config;
}

=head2 quants

Get information about our trading platform configurations for various financial instruments

Example:

    my $config       = BOM::Config::quants();
    my $custom_limit = $config->{risk_profile}{$custom_profile}{payout}{$contract->currency};

Returns a hashref that contains properties of various settings we have for our financial instruments

=cut

sub quants {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/quants_config.yml');
    return $config;
}

=head2 payment_agent

Get information about payment/transaction limits of different ways of payment in our system

Example:

    my $config         = BOM::Config::payment_agent();
    my $day_type       = 'weekday';
    my $withdraw_limit = $config>{transaction_limits}->{withdraw}->{$day_type};

Returns a hashref that contains withdraw / deposit / payment limits of various payment methods
we have in our system

=cut

sub payment_agent {
    my $subdir = $ENV{BOM_TEST_CONFIG} // '';
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/' . $subdir . 'share/paymentagent_config.yml');
    return $config;
}

=head2 identity_verification

    BOM::Config::identity_verification()

Loads and caches configuration for idv providers

=cut

sub identity_verification {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/identity_verification.yml');
    return $config;
}

=head2 crypto_api

Config for connecting to the Crypto API.

Example:

    my $crypto_server = BOM::Config::crypto_api()->{host};

Returns a hashref that contains host and port details to connect to crypto API

=cut

sub crypto_api {
    state $config = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_api.yml');
    return $config;
}

=head2 crypto_internal_api

Config for connecting to the Internal Crypto API.

Example:

    my $crypto_server = BOM::Config::crypto_internal_api()->{host};

Returns a hashref that contains host and port details to connect to the internal crypto API

=cut

sub crypto_internal_api {
    state $config = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_internal_api.yml');
    return $config;
}

=head2 domain

Get brand domain information

Example:

    my $whitelist = BOM::Config::domain()->{whitelist};

Returns a hashref that contains list of registered binary and deriv domains

=cut

sub domain {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/domain.yml');
    return $config;
}

=head2 brand

Get the brand object from available domains

Example:

    my $brand           = BOM::Config::brand();
    my $login_providers = $brand->login_providers();

Returns a L<Brands> object for the brand specified in domain config

=cut

sub brand {
    state $brand = Brands->new(name => domain()->{brand});
    return $brand;
}

=head2 dx_slippage_threshold

Get slippage thresholds for DerivX

Returns a hashref with symbols and their corresponding slippage threshold 

=cut

sub dx_slippage_threshold {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/dx_slippage_threshold.yml');
    return $config;
}

=head2 s3

Get our S3 bucket details

Example:

    my $key = BOM::Config::s3()->{document_auth}->{aws_secret_access_key};

Returns a hashref with credentials to AWS S3 bucket(s). 

=cut

sub s3 {
    state $config = YAML::XS::LoadFile('/etc/rmg/s3.yml');
    return $config;
}

=head2 feed_rpc

Get our feed related storage credentials

Example:

    my $uri = BOM::Config::feed_rpc()->{writer}->{feeddb_uri};

Returns a hashref with details of feed DB. 

=cut

sub feed_rpc {
    state $config = YAML::XS::LoadFile('/etc/rmg/feed_rpc.yml');
    return $config;
}

=head2 sanction_file

Get location of our sanctions file

Example:

    my $sanctions = Data::Validate::Sanctions->new(
        sanction_file => BOM::Config::sanction_file(),
        eu_token      => BOM::Config::third_party()->{eu_sanctions}->{token},
        hmt_url       => BOM::Config::Runtime->instance->app_config->compliance->sanctions->hmt_consolidated_url,
    );

Returns the path of the sanctions file as a string. 

=cut

sub sanction_file {
    return "/var/lib/binary/sanctions.yml";
}

=head2 p2p_payment_methods

Payment method list for P2P.

Example:

    my $methods = BOM::Config::p2p_payment_methods();

Returns the a hashref containing list of payment methods supported for P2P transactions

=cut

sub p2p_payment_methods {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/p2p_payment_methods.yml');
    return $config;
}

{
    my $env = do {
        local @ARGV = ('/etc/rmg/environment');
        readline;
    };
    chomp $env;

    sub env {
        return $env;
    }
}

=head2 on_production

evaluates to True when the service is on production

=cut

sub on_production {
    return env() eq 'production';
}

=head2 on_qa

evaluates to True when the service is on QA machine

=cut

sub on_qa {
    return env() =~ /^qa/;
}

=head2 cashier_env

Only useful in QA Box. For production check L<on_production>

Returns the cashier environment. C<'Test'> or C<'Stage'>.

=cut

sub cashier_env {
    my $cashier_env = third_party->{doughflow}->{environment} // 'Test';
    return $cashier_env;
}

=head2 cashier_config

Returns the configuraiton for the available cashier, as defiend in
the L<cashier.yml> file.

=cut

sub cashier_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/cashier.yml');
    return $config;
}

=head2 on_ci

check whether the running environment is ci environment or not

=cut

sub on_ci {
    return env() eq 'ci';
}

=head2 redis_replicated_config

loads and caches the redis replicated config

=cut

sub redis_replicated_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-replicated.yml');
    return $config;
}

=head2 redis_pricer_config

loads and caches the redis pricer config

=cut

sub redis_pricer_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer.yml');
    return $config;
}

=head2 redis_replicated_config

loads and caches the redis pricer subscription config

=cut

sub redis_pricer_subscription_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer-subscription.yml');
    return $config;
}

=head2 redis_pricer_shared_config

loads and caches the redis pricer shared config

=cut

sub redis_pricer_shared_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer-shared.yml');
    return $config;
}

=head2 redis_exchangerates_config

loads and caches the redis exchange rates config

=cut

sub redis_exchangerates_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-exchangerates.yml');
    return $config;
}

=head2 redis_feed_config

loads and caches the redis feed config

=cut

sub redis_feed_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-feed.yml');
    return $config;
}

=head2 redis_mt5_user_config

loads and caches the redis MT5 user config

=cut

sub redis_mt5_user_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-mt5user.yml');
    return $config;
}

=head2 redis_cfds_config

loads and caches the redis events config

=cut

sub redis_events_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-events.yml');
    return $config;
}

=head2 redis_rpc_config

loads and caches the redis RPC config

=cut

sub redis_rpc_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-rpc.yml');
    return $config;
}

=head2 redis_transaction_config

loads and caches the redis transaction config

=cut

sub redis_transaction_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-transaction.yml');
    return $config;
}

=head2 redis_limit_settings

loads and caches the redis limit settings

=cut

sub redis_limit_settings {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-transaction-limits.yml');
    return $config;
}

=head2 redis_auth_config

loads and caches the redis auth config

=cut

sub redis_auth_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-auth.yml');
    return $config;
}

=head2 redis_expiryq_config

loads and caches the redis expiry queue config

=cut

sub redis_expiryq_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_AUTH} // '/etc/rmg/redis-expiryq.yml');
    return $config;
}

=head2 redis_p2p_config

loads and caches the redis P2P config

=cut

sub redis_p2p_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-p2p.yml');
    return $config;
}

=head2 redis_ws_config

loads and caches the redis websocket config

=cut

sub redis_ws_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml');
    return $config;
}

=head2 derivez_server_routing_by_country

Config for trade server routing for derivez for each countries.

=cut

sub derivez_server_routing_by_country {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/derivez_server_routing_by_country.yml');
    return $config;
}

=head2 mt5_account_types

Config for MT5 groups definition

=cut

sub mt5_account_types {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5_account_types.yml');
    return $config;
}

=head2 mt5_assets_config

Config for MT5 assets

=cut

sub mt5_assets_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5_assets.yml');
    return $config;
}

=head2 mt5_webapi_config

Config for trade server definition for MT5

=cut

sub mt5_webapi_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/mt5webapi.yml');
    return $config;
}

=head2 mt5_symbols_config

Config for mt5 to deriv symbols mapping, where the key is MT5 symbol and value is Deriv symbol.

=cut

sub mt5_symbols_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5-symbols.yml');
    return $config;
}

=head2 redis_payment_config

    BOM::Config::redis_payment_config()

Loads and caches configuration for payment Redis instance

Returns the loaded config

=cut

sub redis_payment_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-payment.yml');
    return $config;
}

=head2 qa_config

Loads configuration file for QA devbox, available only on QA.

=cut

sub qa_config {
    state $config = YAML::XS::LoadFile('/etc/qa/config.yml');
    return $config;
}

=head2 paymentapi_config

Loads and caches configuration for PaymentAPI

Returns the loaded config

=cut

sub paymentapi_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/paymentapi.yml');
    return $config;
}

=head2 redis_cfds_config

    BOM::Config::redis_cfds_config()

Loads and caches configuration for CFDs Redis instance

=cut

sub redis_cfds_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-cfds.yml');
    return $config;
}

=head2 redis_ctrader_config

    BOM::Config::redis_ctrader_config()

Loads and caches configuration for cTrader Redis instance

=cut

sub redis_ctrader_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-ctrader-bridge.yml');
    return $config;
}

=head2 services_config

    BOM::Config::services_config()

Loads and caches configuration for internal services

=cut

sub services_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/services.yml');
    return $config;
}

=head2 account_types

Loads and caches configuration for account types

=cut

sub account_types {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/account_types.yml');

    return $config;
}

=head2 broker_databases

Loads and caches configuration for broker code databases.

=cut

sub broker_databases {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/broker_databases.yml');

    return $config;
}

=head2 ctrader_countryid

Config for cTrader's country to interger id mapping

=cut

sub ctrader_countryid {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/ctrader_countryid.yml');
    return $config;
}

=head2 ctrader_proxy_api_config

Config for ctrader proxy container url

=cut

sub ctrader_proxy_api_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/ctrader_proxy_api.yml');
    return $config;
}

=head2 thinkific_config

    BOM::Config::thinkific_config()

Loads and caches configuration for thinkific (Deriv Academy)

=cut

sub thinkific_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/thinkific.yml');
    return $config;
}

=head2 dynamic_leverage_config

    BOM::Config::dynamic_leverage_config()

Config for dynamic leverage for trading platform

=cut

sub dynamic_leverage_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/cfd/leverage/metatrader/default.yml');
    return $config;
}

=head2 ctrader_general_configurations

This subroutine loads the cTrader account types configuration from a YAML file. It uses a state variable to cache the configuration, ensuring that the file is only loaded once during the program's execution.

=head3 Notes

The configuration file is set to '/home/git/regentmarkets/bom-config/share/ctrader_general_configurations.yml'. If there's a need to load a different file or update the configuration dynamically, modifications to the subroutine would be required.

=cut

sub ctrader_general_configurations {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/ctrader_general_configurations.yml');
    return $config;
}

=head2 ctrader_account_types

Config for cTrader groups definition

=cut

sub ctrader_account_types {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/ctrader_account_types.yml');
    return $config;
}

=head2 growthbook_config

    BOM::Config::growthbook_config()

Loads and caches configuration for Growthbook credentials

=cut

sub growthbook_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/growthbook.yml');
    return $config;
}

=head2 status_hierarchy

Gets the hierarchy of statuses to define sub statuses

Example:

    my $status_tree       = BOM::Config::status_hierarchy->{hierarchy};
    my $disabled_children = $config->{disabled};

Returns a hashref representing the hierarchy of statuses where each key is a status code and the value corresponding to it is an array of strings, as children of the status code in key.

=cut

sub status_hierarchy {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/status_hierarchy.yml');
    return $config;
}

=head2 cfds_kyc_status_config

    BOM::Config::cfds_kyc_status_config()

Config for kyc status for cfds trading platform

=cut

sub cfds_kyc_status_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/cfd/know-your-customer/cfds_kyc_status.yml');
    return $config;
}

=head2 cfds_jurisdiction_config

    BOM::Config::cfds_jurisdiction_config()

Config for cfds trading platform jurisdiction

=cut

sub cfds_jurisdiction_config {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/cfd/jurisdiction/cfds_jurisdiction.yml');
    return $config;
}

1;

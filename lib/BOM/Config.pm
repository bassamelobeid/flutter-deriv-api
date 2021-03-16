package BOM::Config;

use strict;
use warnings;

use feature "state";
use YAML::XS;
use Brands;

sub node {
    state $config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    return $config;
}

sub feed_listener {
    state $config = YAML::XS::LoadFile('/etc/rmg/feed_listener.yml');
    return $config;
}

sub aes_keys {
    state $config = YAML::XS::LoadFile('/etc/rmg/aes_keys.yml');
    return $config;
}

sub randsrv {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_RAND} // '/etc/rmg/randsrv.yml');
    return $config;
}

sub third_party {
    state $config = YAML::XS::LoadFile('/etc/rmg/third_party.yml');
    return $config;
}

sub backoffice {
    state $config = YAML::XS::LoadFile('/etc/rmg/backoffice.yml');
    return $config;
}

sub currency_pairs_backoffice {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/currency_config.yml');
    return $config;
}

sub quants {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/quants_config.yml');
    return $config;
}

sub payment_agent {
    my $subdir = $ENV{BOM_TEST_CONFIG} // '';
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/' . $subdir . 'share/paymentagent_config.yml');
    return $config;
}

sub payment_limits {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/payment_limits.yml');
    return $config;
}

sub client_limits {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/client_limits.yml');
    return $config;
}

sub crypto {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/crypto_config.yml');
    return $config;
}

sub domain {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/domain.yml');
    return $config;
}

sub brand {
    state $brand = Brands->new(name => domain()->{brand});
    return $brand;
}

sub s3 {
    state $config = YAML::XS::LoadFile('/etc/rmg/s3.yml');
    return $config;
}

sub feed_rpc {
    state $config = YAML::XS::LoadFile('/etc/rmg/feed_rpc.yml');
    return $config;
}

sub sanction_file {
    return "/var/lib/binary/sanctions.yml";
}

sub financial_assessment_fields {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/financial_assessment_structure.yml');
    return $config;
}

sub social_responsibility_thresholds {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/social_responsibility_thresholds.yml');
    return $config;
}

=head2 p2p_payment_methods

Payment method list for P2P.

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

sub on_production {
    return env() eq 'production';
}

sub on_qa {
    return env() =~ /^qa/;
}

=head2 on_ci

check whether the running environment is ci environment or not

=cut

sub on_ci {
    return env() eq 'ci';
}

sub redis_replicated_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-replicated.yml');
    return $config;
}

sub redis_pricer_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer.yml');
    return $config;
}

sub redis_pricer_subscription_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer-subscription.yml');
    return $config;
}

sub redis_pricer_shared_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-pricer-shared.yml');
    return $config;
}

sub redis_exchangerates_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-exchangerates.yml');
    return $config;
}

sub redis_feed_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-feed.yml');
    return $config;
}

sub redis_mt5_user_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-mt5user.yml');
    return $config;
}

sub redis_events_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-events.yml');
    return $config;
}

sub redis_rpc_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-rpc.yml');
    return $config;
}

sub redis_transaction_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-transaction.yml');
    return $config;
}

sub redis_limit_settings {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-transaction-limits.yml');
    return $config;
}

sub redis_auth_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-auth.yml');
    return $config;
}

sub redis_expiryq_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_AUTH} // '/etc/rmg/redis-expiryq.yml');
    return $config;
}

sub redis_p2p_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/redis-p2p.yml');
    return $config;
}

sub redis_ws_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml');
    return $config;
}

sub mt5_user_rights {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5_user_rights.yml');
    return $config;
}

=head2 mt5_server_routing

Config for trade server routing for MT5.

=cut

sub mt5_server_routing {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5_server_routing_by_country.yml');
    return $config;
}

sub mt5_account_types {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/mt5_account_types.yml');
    return $config;
}

=head2 mt5_webapi_config

Config for trade server definition for MT5

=cut

sub mt5_webapi_config {
    state $config = YAML::XS::LoadFile('/etc/rmg/mt5webapi.yml');
    return $config;
}

sub onfido_supported_documents {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/onfido_supported_documents.yml');
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

1;

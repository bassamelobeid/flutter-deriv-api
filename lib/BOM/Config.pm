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

sub role {
    return (any { $_ eq shift } @{BOM::Config::node()->{node}->{roles}});
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

# This function should not be around, development environment is legacy
# This needs further discussion to make sure all agree to remove this environment
# TODO: ~Jack
sub on_development {
    return env() =~ /^development/;
}

sub redis_replicated_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml');
    return $config;
}

sub redis_pricer_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
    return $config;
}

sub redis_exchangerates_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-exchangerates.yml');
    return $config;
}

sub redis_feed_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_FEED} // '/etc/rmg/redis-feed.yml');
    return $config;
}

sub redis_mt5_user_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_MT5_USER} // '/etc/rmg/redis-mt5user.yml');
    return $config;
}

sub redis_events_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_EVENTS} // '/etc/rmg/redis-events.yml');
    return $config;
}

sub redis_transaction_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_TRANSACTION} // '/etc/rmg/redis-transaction.yml');
    return $config;
}

sub redis_queue_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_QUEUE} // '/etc/rmg/redis-queue.yml');
    return $config;
}

sub redis_limit_settings {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-transaction-limits.yml');
    return $config;
}

sub redis_auth_config {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_AUTH} // '/etc/rmg/redis-auth.yml');
    return $config;
}

1;

#!/usr/bin/perl

use strict;
use warnings;

use BOM::Product::QuantsConfig;
use BOM::MarketData qw(create_underlying);

use Test::More;
use Test::Exception;
use Test::FailWarnings;

subtest 'exceptions' => sub {
    my $u  = create_underlying('frxUSDJPY');
    my $qc = BOM::Product::QuantsConfig->new;
    throws_ok { $qc->get_config() } qr/Missing required parameter/, 'throws exception if required parameters are missing';
    my $args = {
        config_type      => 'limits',
        barrier_category => 'atm',
        expiry_type      => 'multiday',
        config_name      => 'potential_loss',
        underlying       => $u,
    };
    lives_ok { $qc->get_config($args) } 'get_config with valid parameters';
    throws_ok { $qc->get_config({%$args, config_type => 'unknown'}) } qr/Unsupported config_type/, 'throws exception if config_type is unsupported';
    throws_ok { $qc->get_config({%$args, barrier_category => 'unknown'}) } qr/Unsupported barrier_category/,
        'throws exception if barrier_category is unsupported';
    throws_ok { $qc->get_config({%$args, expiry_type => 'unknown'}) } qr/Unsupported expiry_type/, 'throws exception if expiry_type is unsupported';
    throws_ok { $qc->get_config({%$args, config_name => 'unknown'}) } qr/Unsupported config_name/, 'throws exception if config_name is unsupported';
};

done_testing();

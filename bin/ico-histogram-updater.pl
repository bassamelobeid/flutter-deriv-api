#!/usr/bin/env perl 
use strict;
use warnings;

no indirect;

use JSON::MaybeXS;
use Date::Utility;
use Time::HiRes;
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc stats_gauge);
use Unicode::UTF8 qw(encode_utf8);
use List::UtilsBy qw(nsort_by);
use Format::Util::Numbers qw/financialrounding/;
use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);
use Mojo::Redis2;
use YAML::XS;

use LandingCompany::Registry;
use BOM::Platform::Runtime;
use BOM::Database::ClientDB;
use BOM::Platform::RedisReplicated;

# How wide each ICO histogram bucket is, in USD
use constant ICO_BUCKET_SIZE => 0.20;

my $json = JSON::MaybeXS->new;

sub update_histogram {
    my $start    = Time::HiRes::time();
    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
        operation   => 'replica',
    });
    my $buckets = $clientdb->db->dbh->selectall_arrayref('select * from ico_histogram(?)', {Slice => {}}, ICO_BUCKET_SIZE);

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    my $redis      = BOM::Platform::RedisReplicated::redis_write();
    for my $currency (sort keys %{LandingCompany::Registry::get('costarica')->legal_allowed_currencies}) {
        my $count     = 0;
        my $total_usd = 0;
        my %sum;
        for my $bucket (@$buckets) {
            # Ensure we have the right precision, database itself should
            # already be giving us sensible values so we don't expect
            # actual rounding here.
            my $key = financialrounding(
                price => 'USD',
                $bucket->{bucket});
            $sum{$key} += $bucket->{total_price};
            $total_usd += $bucket->{total_price};
            $count     += $bucket->{tokens};
        }
        $total_usd = financialrounding(
            price => 'USD',
            $total_usd
        );
        $_ = financialrounding(
            price => 'USD',
            $_
        ) for values %sum;

        my $minimum_bid_usd = financialrounding(
            price => 'USD',
            $app_config->system->suspend->ico_minimum_bid_in_usd
        );
        my $minimum_bid = financialrounding(
            price => $currency,
            amount_from_to_currency($minimum_bid_usd, USD => $currency));
        if ($currency eq 'USD') {
            stats_gauge('binary.ico.bids.count',     $count);
            stats_gauge('binary.ico.bids.total_usd', $total_usd);
        }
        $redis->set(
            'ico::status::' . $currency,
            encode_utf8(
                $json->encode({
                        currency              => $currency,
                        histogram_bucket_size => ICO_BUCKET_SIZE,
                        minimum_bid           => $minimum_bid,
                        minimum_bid_usd       => $minimum_bid_usd,
                        histogram             => \%sum
                    })));
    }
    my $elapsed = 1000.0 * (Time::HiRes::time() - $start);
    stats_timing('binary.ico.bids.calculation.elapsed', $elapsed);
    return;
}

sub run {
    my $cfg = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml')->{write};
    my $uri = URI->new('redis://localhost');
    $uri->host($cfg->{host})                   if length($cfg->{host}     // '');
    $uri->port($cfg->{port})                   if length($cfg->{port}     // '');
    $uri->userinfo('user:' . $cfg->{password}) if length($cfg->{password} // '');
    my $redis = Mojo::Redis2->new(
        # Stringify since Mojolicious ecosystem does not support URI
        url => "$uri",
    );
    $redis->on(
        message => sub {
            update_histogram();
        });
    $redis->on(
        error => sub {
            my ($self, $err) = @_;
            warn "Redis error reported - $err\n";
            Mojo::IOLoop->stop if Mojo::IOLoop->is_running;
        });
    $redis->subscribe(
        ['ico::bid'],
        sub {
            my ($redis, $err) = @_;
            return unless $err;
            warn "Failed to subscribe - $err";
            Mojo::IOLoop->stop if Mojo::IOLoop->is_running;
        });
    update_histogram();
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
    return;
}

run() unless caller;

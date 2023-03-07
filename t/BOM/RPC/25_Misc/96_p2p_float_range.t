use strict;
use warnings;
use Test::Most;
use BOM::Test::RPC::QueueClient;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use JSON::MaybeXS                              qw(decode_json encode_json);

my $c = BOM::Test::RPC::QueueClient->new();

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR EURS PAX ETH IDK AUD eUSDT tUSDT BTC USDK LTC USB UST USDC TUSD USD GBP DAI BUSD);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

subtest 'float rate offset limit for different range of inputs' => sub {

    my $config     = BOM::Config::Runtime->instance->app_config;
    my $p2p_config = $config->payments->p2p;
    $p2p_config->restricted_countries(['au']);

    my %params = (
        website_status => {
            language     => 'EN',
            country_code => 'id',
            args         => {website_status => 1}});

    my %rates = (
        0.123            => "0.06",
        0.0123           => "0.00",
        0.00123          => "0.00",
        4                => "2.00",
        8.2              => "4.10",
        8.16             => "4.08",
        10.              => "5.00",
        16.00            => "8.00",
        111.995          => "55.99",
        19.9499999999999 => "9.97",
        1230.9976        => "615.49",
    );

    for my $rate (keys %rates) {
        $p2p_config->float_rate_global_max_range($rate);
        my $resp = $c->call_ok(%params)->result->{p2p_config};
        is $resp->{float_rate_offset_limit}, $rates{$rate}, 'rate calculated correctly';
        ok abs($resp->{float_rate_offset_limit}) <= ($p2p_config->float_rate_global_max_range) / 2, 'float rate falls within accepted range';
    }
};

done_testing();

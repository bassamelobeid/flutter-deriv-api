use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;

my %fake_config;
my $revision = 1;

my $mock_app_config = Test::MockModule->new('App::Config::Chronicle', no_auto => 1);
$mock_app_config->mock(
    'set' => sub {
        my ($self, $conf) = @_;
        for (keys %$conf) {
            $fake_config{$_} = $conf->{$_};
        }
    },
    'get' => sub {
        my ($self, $key) = @_;
        if (ref($key) eq 'ARRAY') {
            my %result = map {
                my $value = (defined $fake_config{$_}) ? $fake_config{$_} : $mock_app_config->original('get')->($_);
                $_ => $value
            } @{$key};
            return \%result;
        }
        return $fake_config{$key} if ($fake_config{$key});
        return $mock_app_config->original('get')->(@_);
    },
    'loaded_revision' => sub {
        return $revision;
    });

subtest 'get_crypto_withdrawal_min_usd' => sub {

    my @all_crypto_currencies = LandingCompany::Registry::all_crypto_currencies();
    my @crypto_currency       = grep { !BOM::Config::CurrencyConfig::is_crypto_currency_suspended($_) } @all_crypto_currencies;

    my $mock_min_usd_settings = {map { $_ => int(rand(100)) } @crypto_currency};

    my $app_config = BOM::Config::Runtime->instance->app_config();

    # Change the config
    $app_config->set({'payments.crypto.withdrawal.min_usd' => JSON::MaybeUTF8::encode_json_utf8($mock_min_usd_settings)});

    cmp_ok(
        0 + BOM::Config::CurrencyConfig::get_crypto_withdrawal_min_usd($_),
        '==',
        $mock_min_usd_settings->{$_},
        "get_crypto_withdrawal_min_usd:Correct Minimum withdrawal in USD for $_"
    ) for @crypto_currency;

};

$mock_app_config->unmock_all();

done_testing();

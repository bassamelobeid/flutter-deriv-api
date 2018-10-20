use strict;
use warnings;

use Test::More;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;

subtest 'transfer_between_accounts' => sub {
    my %fake_config = (
        'payments.transfer_between_accounts.minimum.by_currency'    => '{}',
        'payments.transfer_between_accounts.minimum.default.crypto' => 0.002,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 1
    );

    my $mock_app_config = Test::MockModule->new('App::Config::Chronicle', no_auto => 1);
    $mock_app_config->mock(
        'set' => sub {
            my ($self, $conf) = @_;
            for (keys %$conf) {
                if ($fake_config{$_}) {
                    $fake_config{$_} = $conf->{$_};
                } else {
                    $mock_app_config->original('set')->({$_ => $conf->{$_}});
                }
            }
        },
        'get' => sub {
            my ($self, $key) = @_;
            if (ref($key) eq 'ARRAY') {
                my %result = map {
                    my $value = ($fake_config{$_}) ? $fake_config{$_} : $mock_app_config->original('get')->($_);
                    $_ => $value
                } @{$key};
                return \%result;
            }
            return $fake_config{$key} if ($fake_config{$key});
            return $mock_app_config->original('get')->(@_);
        });

    my $fake_minimum = {
        "USD" => 10,
        "GBP" => 11,
        "BTC" => 200,
        "UST" => 210
    };
    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->set({
        'payments.transfer_between_accounts.minimum.by_currency'    => JSON::MaybeUTF8::encode_json_utf8($fake_minimum),
        'payments.transfer_between_accounts.minimum.default.crypto' => 9,
        'payments.transfer_between_accounts.minimum.default.fiat'   => 90,
    });

    my @all_currencies  = LandingCompany::Registry::all_currencies();
    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();

    foreach (@all_currencies) {
        my $type = LandingCompany::Registry::get_currency_type($_);
        my $min_default = ($type eq 'crypto') ? 9 : 90;

        cmp_ok($transfer_limits->{$_}->{min}, '==', $fake_minimum->{$_} // $min_default, "Transfer between account minimum is correct for $_");
    }

    $mock_app_config->unmock_all();
};

done_testing();

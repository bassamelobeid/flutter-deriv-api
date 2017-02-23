#!/etc/rmg/bin/perl
use strict;
use warnings;
use 5.010;

use AnyEvent;
use AnyEvent::Redis;
use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(reinitialise_offerings);
use YAML::XS qw/LoadFile/;
use JSON::XS;

my $chronicle_config = LoadFile('/etc/rmg/chronicle.yml');

my $cv_finish = AE::cv;
my $redis     = AnyEvent::Redis->new(
    host     => $chronicle_config->{read}->{host},
    port     => $chronicle_config->{read}->{port},
    encoding => 'utf8',
    on_error => sub {
        warn @_;
        $cv_finish->send;
    },
);

print "refreshing offerings (on start)\n";
my $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;
reinitialise_offerings($offerings_config);

my $offering_config_digest = LandingCompany::Offerings::_get_config_key($offerings_config);

print "offerings has been refreshed, digest = $offering_config_digest\n";

my $cv = $redis->subscribe(
    "app_settings::binary",
    sub {
        print("received new config\n");
        my ($message, $channel) = @_;
        return unless $message;

        my $data = decode_json($message);

        # follows the logic in BOM::Platform::Runtime::get_offerings_config
        my $config = {};
        $config->{suspend_trading}        = $data->{global}->{system}->{suspend}->{trading};
        $config->{suspend_trades}         = $data->{global}->{quants}->{underlyings}->{suspend_trades};
        $config->{suspend_buy}            = $data->{global}->{quants}->{underlyings}->{suspend_buy};
        $config->{suspend_contract_types} = $data->{global}->{quants}->{features}->{suspend_contract_types};

        $config->{disabled_due_to_corporate_actions} = $data->{global}->{quants}->{underlyings}->{disabled_due_to_corporate_actions};
        $config->{disabled_markets}                  = $data->{global}->{quants}->{markets}->{disabled};

        my $new_digest = LandingCompany::Offerings::_get_config_key($config);
        if ($new_digest ne $offering_config_digest) {
            print("Found new offerings config, refreshing, digest: $new_digest\n");
            reinitialise_offerings($config);
            print("Offerings refreshing complete\n");
            $offering_config_digest = $new_digest;
        } else {
            print("No need to refresh offerings\n");
        }
        return;
    });

$cv_finish->recv;


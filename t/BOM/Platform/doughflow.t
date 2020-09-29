use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Platform::Doughflow qw(get_sportsbook);
use LandingCompany::Registry;

my @doughflow_sportsbooks_mock = (
    'Binary (CR) SA USD',
    'Binary (CR) SA EUR',
    'Binary (CR) SA AUD',
    'Binary (CR) SA GBP',
    'Binary (Europe) Ltd GBP',
    'Binary (Europe) Ltd EUR',
    'Binary (Europe) Ltd USD',
    'Binary (IOM) Ltd GBP',
    'Binary (IOM) Ltd USD',
    'Binary Investments Ltd USD',
    'Binary Investments Ltd EUR',
    'Binary Investments Ltd GBP',
);

my @doughflow_deriv_sportsbooks_mock = (
    'Deriv (SVG) LLC USD',
    'Deriv (SVG) LLC EUR',
    'Deriv (SVG) LLC AUD',
    'Deriv (SVG) LLC GBP',
    'Deriv (Europe) Limited GBP',
    'Deriv (Europe) Limited EUR',
    'Deriv (Europe) Limited USD',
    'Deriv (MX) Ltd GBP',
    'Deriv (MX) Ltd USD',
    'Deriv Investments (Europe) Limited USD',
    'Deriv Investments (Europe) Limited EUR',
    'Deriv Investments (Europe) Limited GBP',
);

sub get_fiat_currencies {
    my $currencies = shift;
    return grep { $currencies->{$_}->{type} eq 'fiat' } keys %{$currencies};
}

subtest 'doughflow_sportsbooks' => sub {
    my %doughflow_sportsbooks = map { $_ => 1 } @doughflow_sportsbooks_mock;
    my @all_broker_codes      = LandingCompany::Registry->all_broker_codes;

    my $config_mocked = Test::MockModule->new('BOM::Config');
    $config_mocked->mock('on_production', sub { return 1 });

    BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks(1); # disable Deriv sportsbooks

    for my $broker (@all_broker_codes) {
        my $lc = LandingCompany::Registry->get_by_broker($broker);

        next if $lc->short =~ /virtual|champion/;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = get_sportsbook($broker, $currency);
            ok exists $doughflow_sportsbooks{$sportsbook}, "'$sportsbook' exists in Doughflow sportsbooks";
        }
    }

    $config_mocked->unmock('on_production');
};

subtest 'doughflow_deriv_sportsbooks' => sub {
    my %doughflow_sportsbooks = map { $_ => 1 } @doughflow_deriv_sportsbooks_mock;
    my @all_broker_codes      = LandingCompany::Registry->all_broker_codes;

    my $config_mocked = Test::MockModule->new('BOM::Config');
    $config_mocked->mock('on_production', sub { return 1 });

    BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks(0); # enable Deriv sportsbooks

    for my $broker (@all_broker_codes) {
        my $lc = LandingCompany::Registry->get_by_broker($broker);

        next if $lc->short =~ /virtual|champion/;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = get_sportsbook($broker, $currency);
            ok exists $doughflow_sportsbooks{$sportsbook}, "'$sportsbook' exists in Doughflow sportsbooks";
        }
    }

    $config_mocked->unmock('on_production');
};

done_testing;

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use LandingCompany::Registry;
use BOM::Config;
use BOM::Config::BrokerDatabase;

subtest 'Load data' => sub {
    my $mock_data   = {};
    my $mock_config = Test::MockModule->new('BOM::Config');
    $mock_config->redefine(broker_databases => sub { return $mock_data });

    like exception { BOM::Config::BrokerDatabase->load_data() }, qr/Some brokers are left without any database domain config/,
        'Correct error for missing broker codes';

    $mock_data = {map { $_ => $_ } LandingCompany::Registry->all_broker_codes};
    is exception { BOM::Config::BrokerDatabase->load_data() }, undef, 'No error with all broker codes';

    delete $mock_data->{VRTC};
    like exception { BOM::Config::BrokerDatabase->load_data() }, qr/Some brokers are left without any database domain config: VRTC/,
        'Correct error for missing broker code VRTC';

    $mock_data->{VRTC}  = 'virtualdb';
    $mock_data->{DUMMY} = 'dummydb';
    like exception { BOM::Config::BrokerDatabase->load_data() }, qr/Invalid brokers found in database domain config: DUMMY/,
        'Correct error for invalid broker code';

    $mock_config->unmock_all;
    BOM::Config::BrokerDatabase->load_data();
};

subtest 'Find database domain' => sub {
    is(BOM::Config::BrokerDatabase->get_domain('DUMMY'), undef, 'No db domain found for dummy broker code');

    for my $broker (LandingCompany::Registry->all_broker_codes) {
        ok(BOM::Config::BrokerDatabase->get_domain($broker), "Database domain found for $broker");
    }
};

done_testing;

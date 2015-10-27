use Test::Most 0.22 (tests => 8);
use Test::NoWarnings;

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::Broker::Codes;
use YAML::XS;

my $broker_codes;
lives_ok {
    $broker_codes = BOM::Platform::Runtime::Broker::Codes->new(
        hosts              => BOM::Platform::Runtime->instance->hosts,
        landing_companies  => BOM::Platform::Runtime->instance->landing_companies,
        broker_definitions => YAML::XS::LoadFile('/etc/rmg/broker_codes.yml'));
}
'Initialized';

subtest 'valid broker codes' => sub {
    ok $broker_codes->get('VRTC'), "Got VRTC Broker";
    is $broker_codes->get('VRTC')->code,     'VRTC', "Got VRTC Broker code";
    is $broker_codes->get('VRTC1234')->code, 'VRTC', "Got VRTC Broker code by login";

    throws_ok { $broker_codes->get('TIMTY') } qr/Unknown broker code or loginid \[TIMTY\]/,     "No Such Broker TIMTY";
    throws_ok { $broker_codes->get('TIMTY1122') } qr/Unknown broker code or loginid \[TIMTY\]/, "No Such Login TIMTY";

    my @brokers = sort map { $_->code } $broker_codes->all;
    eq_or_diff \@brokers, [sort qw(CR MLT MF MX VRTC FOG)], "Got correct list of brokers";

    @brokers = sort $broker_codes->all_codes;
    eq_or_diff \@brokers, [sort qw(CR MLT MF MX VRTC FOG)], "Got correct list of brokers";
};

lives_ok {
    BOM::Platform::Runtime->instance->broker_codes;
}
'Runtime is able to build';

throws_ok {
    BOM::Platform::Runtime->instance->broker_codes->get('RC');
}
qr/Unknown broker code or loginid \[RC\]/, 'Dies with the correct message';

subtest 'Build quality' => sub {
    my $cr = BOM::Platform::Runtime->instance->broker_codes->get('CR');
    is $cr->server->name,           'www',       'dealing server is www';
    is $cr->landing_company->short, 'costarica', 'landing company is BOM CR';
};

subtest 'landing_company_for' => sub {
    my $broker_codes = BOM::Platform::Runtime->instance->broker_codes;

    is $broker_codes->landing_company_for('CR')->short,     'costarica', "Got correct landing company for CR";
    is $broker_codes->landing_company_for('CR1234')->short, 'costarica', "Got correct landing company for CR1234";
    is $broker_codes->landing_company_for('FOG')->short,    'fog',       "Got correct landing company for VRTE";

    throws_ok {
        $broker_codes->landing_company_for('RC');
    }
    qr/Unknown broker code or loginid \[RC\]/, 'Dies with the correct message';
};

subtest 'dealing_server_for' => sub {
    my $broker_codes = BOM::Platform::Runtime->instance->broker_codes;

    is $broker_codes->dealing_server_for('MX')->name,     'www', "Got correct dealing server for MX";
    is $broker_codes->dealing_server_for('MX4321')->name, 'www', "Got correct dealing server for MX4321";

    throws_ok {
        $broker_codes->dealing_server_for('4321MX');
    }
    qr/Unknown broker code or loginid \[4321MX\]/, 'Dealing server for 4321MX is not defined';
};

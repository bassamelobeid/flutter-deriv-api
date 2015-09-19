use Test::Most 0.22 (tests => 5);
use Test::NoWarnings;
use Test::MockModule;
use JSON qw(decode_json);
use File::Basename qw();

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::Website;
use BOM::Platform::Runtime::Broker;
use BOM::Platform::Runtime::LandingCompany;

subtest 'Prepare Website' => sub {
    my $bom = prepare_website();
    BAIL_OUT("Cannot Prepare website") unless ($bom);
};

subtest 'broker_for_new_account' => sub {
    subtest 'Australia' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('au');

        ok $broker, 'Now there is a broker';
        is $broker->code, 'CR', 'CR Broker is the right one';
    };

    subtest 'UK' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('au');

        ok $broker, 'Now there is a broker';
        is $broker->code, 'CR', 'CR Broker is the right one';
    };

    subtest 'Netherlands' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('nl');

        ok $broker, 'Now there is a broker';
        is $broker->code, 'MLT', 'MLT Broker is the right one';
    };

    subtest 'France' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('fr');

        ok $broker, 'Now there is a broker';
        is $broker->code, 'MF', 'MF Broker is the right one';
    };

    subtest 'Germany' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('de');

        ok $broker, 'Now there is a broker';
        is $broker->code, 'MF', 'MF Broker is the right one';
    };

    subtest 'Malaysia' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('my');
        is $broker->code, 'CR', 'restricted countries [Malaysia], default to CR';
    };

    subtest 'Malta' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_account('mt');
        is $broker->code, 'CR', 'restricted countries [Malta], default to CR';
    };
};

subtest 'broker_for_new_financial' => sub {
    subtest 'Australia' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('au');

        ok $broker, 'broker ok';
        is $broker->code, 'CR', 'CR ok';
    };

    subtest 'UK' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('gb');

        ok $broker, 'broker ok';
        is $broker->code, 'MX', 'MX ok';
    };

    subtest 'Netherlands' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('nl');

        ok $broker, 'broker ok';
        is $broker->code, 'MF', 'MF ok';
    };

    subtest 'France' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('fr');

        ok $broker, 'broker ok';
        is $broker->code, 'MF', 'MF ok';
    };

    subtest 'Malaysia' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('my');
        is $broker, undef, 'no broker';
    };

    subtest 'Malta' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_financial('mt');
        is $broker, undef, 'no broker';
    };
};

subtest 'broker_for_new_virtual' => sub {
    subtest 'Default virtual broker code' => sub {
        my $bom    = prepare_website();
        my $broker = $bom->broker_for_new_virtual();

        ok $broker, 'Now there is a broker';
        is $broker->code, 'VRTC', 'VRTC Broker is the right one';
    };
};

sub prepare_website {
    my $costarica = BOM::Platform::Runtime::LandingCompany->new(
        short   => 'costarica',
        name    => 'Binary (C.R.) S.A.',
        address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
        fax     => '+44 207 6813557',
        country => 'Costa Rica',
    );
    isa_ok $costarica, 'BOM::Platform::Runtime::LandingCompany';

    my $cr = BOM::Platform::Runtime::Broker->new(
        code                   => 'CR',
        server                 => 'localhost',
        landing_company        => $costarica,
        transaction_db_cluster => 'CR',
    );
    isa_ok $cr, 'BOM::Platform::Runtime::Broker';

    my $ci = BOM::Platform::Runtime::Broker->new(
        code                   => 'CI',
        server                 => 'localhost',
        landing_company        => $costarica,
        transaction_db_cluster => 'CI',
    );
    isa_ok $ci, 'BOM::Platform::Runtime::Broker';

    my $vrtc = BOM::Platform::Runtime::Broker->new(
        code                   => 'VRTC',
        server                 => 'localhost',
        landing_company        => $costarica,
        transaction_db_cluster => 'VRTC',
        is_virtual             => 1,
    );
    isa_ok $vrtc, 'BOM::Platform::Runtime::Broker';

    my $iom = BOM::Platform::Runtime::LandingCompany->new(
        short   => 'iom',
        name    => 'Binary (IOM) Ltd',
        address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
        fax     => '+44 207 6813557',
        country => 'Isle of Man',
    );
    isa_ok $iom, 'BOM::Platform::Runtime::LandingCompany';

    my $mx = BOM::Platform::Runtime::Broker->new(
        code                   => 'MX',
        server                 => 'localhost',
        landing_company        => $iom,
        transaction_db_cluster => 'MX',
    );
    isa_ok $mx, 'BOM::Platform::Runtime::Broker';

    my $maltainvest = BOM::Platform::Runtime::LandingCompany->new(
        short   => 'maltainvest',
        name    => 'Binary (Europe) Ltd',
        address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
        fax     => '+44 207 6813557',
        country => 'Isle of Man',
    );

    isa_ok $maltainvest, 'BOM::Platform::Runtime::LandingCompany';
    my $mf = BOM::Platform::Runtime::Broker->new(
        code                   => 'MF',
        server                 => 'localhost',
        landing_company        => $maltainvest,
        transaction_db_cluster => 'MLT',
    );
    isa_ok $mf, 'BOM::Platform::Runtime::Broker';

    my $malta = BOM::Platform::Runtime::LandingCompany->new(
        short   => 'malta',
        name    => 'Binary (Europe) Ltd',
        address => ["First Floor, Millennium House", "Victoria Road", "Douglas", "IM2 4RW", "Isle of Man", "British Isles"],
        fax     => '+44 207 6813557',
        country => 'Isle of Man',
    );

    isa_ok $malta, 'BOM::Platform::Runtime::LandingCompany';
    my $mlt = BOM::Platform::Runtime::Broker->new(
        code                   => 'MLT',
        server                 => 'localhost',
        landing_company        => $malta,
        transaction_db_cluster => 'MLT',
    );
    isa_ok $mlt, 'BOM::Platform::Runtime::Broker';

    my $bom = BOM::Platform::Runtime::Website->new(
        name         => 'Binary',
        primary_url  => 'www.binary.com',
        broker_codes => [$cr, $mx, $mlt, $mf, $vrtc, $ci],
        localhost    => BOM::Platform::Runtime->instance->hosts->localhost,
    );

    isa_ok $bom, 'BOM::Platform::Runtime::Website';
    return $bom;
}

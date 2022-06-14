use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Fatal;
use Test::Exception;

use BOM::Config::Onfido;
use Locale::Codes::Country qw(country_code2code);
use Test::Deep;

my $id_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport'];
my $ng_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport', 'Voter Id'];
my $gh_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport'];

subtest 'Check supported documents ' => sub {
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('ID'), $id_supported_docs, 'Indonesia supported type is correct');
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('NG'), $ng_supported_docs, 'Nigeria supported type is correct');
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('GH'), $gh_supported_docs, 'Ghana supported type is correct');
};

subtest 'Check supported country ' => sub {
    ok BOM::Config::Onfido::is_country_supported('ID'), 'Indonesia is supported';
    ok BOM::Config::Onfido::is_country_supported('AO'), 'Bangladesh is supported';
    ok BOM::Config::Onfido::is_country_supported('GH'), 'Ghana is supported';
};

subtest 'Invalid country ' => sub {
    lives_ok { BOM::Config::Onfido::is_country_supported('I213') } 'Invalid county, but it wont die';
    lives_ok { BOM::Config::Onfido::is_country_supported(123) } 'Invalid county, but it wont die';
    is_deeply(BOM::Config::Onfido::supported_documents_for_country(123), [], 'Invalid county, returns empty list');
};

subtest 'disabled countries' => sub {
    my $config = BOM::Config::Onfido::supported_documents_list();

    my $disabled_countries = [map { $_->{disabled} ? $_->{country_code} : () } values $config->@*];

    my $expected_disabled_countries = [
        qw/
            by
            af
            cd
            iq
            ly
            sy
            ru
            cn
            ir
            kp
            /
    ];

    for my $cc ($expected_disabled_countries->@*) {
        ok BOM::Config::Onfido::is_disabled_country($cc),   "$cc is disabled";
        ok !BOM::Config::Onfido::is_country_supported($cc), "$cc is unsupported";
    }

    cmp_bag $disabled_countries, [map { uc(country_code2code($_, 'alpha-2', 'alpha-3')); } $expected_disabled_countries->@*],
        'disabled countries full list';
};

done_testing();

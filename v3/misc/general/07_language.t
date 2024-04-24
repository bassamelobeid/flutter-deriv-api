use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use Encode;
use await;

my $t   = build_wsapi_test();
my $res = $t->await::residence_list({residence_list => 1});
is $res->{msg_type}, 'residence_list';
ok $res->{residence_list};

my $countries = +{ map { ($_->{value} => $_)} $res->{residence_list}->@* };

is_deeply $countries->{ir}, {
    disabled  => 'DISABLED',
    value     => 'ir',
    text      => 'Iran',
    phone_idd => '98',
    identity  => {
        services => {
            idv => {
                documents_supported => {

                },
                is_country_supported => 0,
                has_visual_sample    => 0,
            },
            onfido => {
                documents_supported => {
                    driving_licence => {
                        display_name => 'Driving Licence',
                    },
                    passport => {
                        display_name => 'Passport',
                    },
                },
                is_country_supported => 0,
            }}}};

# test RU
$t   = build_wsapi_test({language => 'RU'});
$res = $t->await::residence_list({residence_list => 1});
ok $res->{residence_list};
$countries = +{ map { ($_->{value} => $_)} $res->{residence_list}->@* };

is_deeply $countries->{au}, {
    value     => 'au',
    text      => decode_utf8('Австралия'),
    phone_idd => '61',
    identity  => {
        services => {
            idv => {
                documents_supported  => {},
                is_country_supported => 0,
                has_visual_sample    => 0,
            },
            onfido => {
                documents_supported => {
                    driving_licence => {
                        display_name => 'Driving Licence',
                    },
                    passport => {
                        display_name => 'Passport',
                    },
                    immigration_status_document => {
                        display_name => 'Immigration Status Document',
                    },
                    national_health_insurance_card => {
                        display_name => 'National Health Insurance Card',
                    },
                    national_identity_card => {
                        display_name => 'National Identity Card',
                    },
                    visa => {
                        display_name => 'Visa',
                    },
                },
                is_country_supported => 1,
            }}}};

# back to EN
$t   = build_wsapi_test();
$res = $t->await::residence_list({residence_list => 1});
ok $res->{residence_list};
$countries = +{ map { ($_->{value} => $_)} $res->{residence_list}->@* };

is_deeply $countries->{ir}, {
    disabled  => 'DISABLED',
    value     => 'ir',
    text      => 'Iran',
    phone_idd => '98',
    identity  => {
        services => {
            idv => {
                documents_supported  => {},
                is_country_supported => 0,
                has_visual_sample    => 0,
            },
            onfido => {
                documents_supported => {
                    driving_licence => {
                        display_name => 'Driving Licence',
                    },
                    passport => {
                        display_name => 'Passport',
                    },
                },
                is_country_supported => 0,
            }}}};

$t->finish_ok;

done_testing();

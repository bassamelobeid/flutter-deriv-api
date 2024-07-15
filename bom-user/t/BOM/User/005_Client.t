#!/etc/rmg/bin/perl
package t::ClientRefactoring::Test2;
use strict;
use warnings;

use utf8;
use Format::Util::Strings qw( defang );
use BOM::User::Client;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(invalidate_object_cache);
use Test::MockModule;
use Date::Utility;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::User;
use BOM::User::Password;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

use Crypt::NamedKeys;
Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');

subtest 'Client getters, setters' => sub {
    my $login_id = 'CR0011';

    # create client object
    my $client;
    Test::Exception::lives_ok {
        $client = BOM::User::Client::get_instance({'loginid' => $login_id});
    }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => $login_id})'";

    is($client->broker, 'CR', 'client broker is CR');

    Test::Exception::lives_ok { $client->first_name('first-name') } "set first name: first-name";
    is($client->first_name, 'first-name', 'client first name is first-name');

    Test::Exception::lives_ok { $client->last_name('tee') } "set last name: tee";
    is($client->last_name, 'tee', 'client last name is tee');

    Test::Exception::lives_ok { $client->email('test@regentmarkets.com') } 'set email: test@regentmarkets.com';
    is($client->email, 'test@regentmarkets.com', 'client email is test@regentmarkets.com');

    my $password = '123456';
    Test::Exception::lives_ok { $client->password($password) } "set pwd 123456";
    is($client->password, $password, 'client password is 123456');

    Test::Exception::lives_ok { $client->salutation('Ms') } 'set salutation: Ms';
    is($client->salutation, 'Ms', 'client salutation is Ms');

    Test::Exception::lives_ok { $client->date_of_birth('1980-01-01') } 'set date of birth: 1980-01-01';
    is($client->date_of_birth =~ /^1980-01-01/, 1, 'client date of birth is 1980-01-01');

    Test::Exception::lives_ok { $client->residence('au') } 'set residence: au';
    is($client->residence, 'au', 'client residence is au');

    Test::Exception::lives_ok { $client->city('Cyberjaya') } 'set city: Cyberjaya';
    is($client->city, 'Cyberjaya', 'client city is Cyberjaya');

    Test::Exception::lives_ok { $client->citizen('au') } 'set citizen: au';
    is($client->citizen, 'au', 'client citizen is au');

    Test::Exception::lives_ok { $client->address_1('Jln Address 1') } 'set address_1: Jln Address 1';
    is($client->address_1, 'Jln Address 1', 'client address_1 is: Jln Address 1');

    Test::Exception::lives_ok { $client->address_2('Jln Address 2') } 'set address_2: Jln Address 2';
    is($client->address_2, 'Jln Address 2', 'client address_2 is: Jln Address 2');

    Test::Exception::lives_ok { $client->state('VIC') } 'set state: VIC';
    is($client->state, 'VIC', 'client state is: VIC');

    Test::Exception::lives_ok { $client->postcode('55010') } 'set postcode: 55010';
    is($client->postcode, '55010', 'client postcode is: 55010');

    Test::Exception::lives_ok { $client->date_joined('2009-02-20 06:08:00') } 'set date_joined: 2009-02-20 06:08:00GMT';
    is($client->date_joined, '2009-02-20 06:08:00', 'client date_joined is: 2009-02-20 06:08:00');

    my $latest_env =
        defang('16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=');
    Test::Exception::lives_ok { $client->latest_environment($latest_env) } "set latest env: $latest_env";
    is($client->latest_environment, $latest_env, "client latest_environment is: $latest_env");

    # This was the original test case provided with ticket #593, believe it or
    # not. https://bitbucket.org/binarydotcom/bom/issue/593
    Test::Exception::lives_ok {
        $client->secret_question("Carlos Lima's homies live here")
    }
    "set secret question: Carlos Lima's homies live here";
    is($client->secret_question, "Carlos Lima's homies live here", "client secret question is: Carlos Lima's homies live here");

    Test::Exception::lives_ok { $client->secret_answer("São Paulo") } "set secret answer: São Paulo";
    is($client->secret_answer, "São Paulo", "client secret answer is: São Paulo");

    Test::Exception::lives_ok {
        $client->secret_answer("ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ");
    }
    "set secret answer: Unicode test";
    is($client->secret_answer, "ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ", "client secret answer is: Unicode test");

    Test::Exception::lives_ok { $client->promo_code_checked_in_myaffiliates(1) } "set promo_code_checked_in_myaffiliates: 1";
    is($client->promo_code_checked_in_myaffiliates, 1, "client promo_code has been checked in MyAffiliates.");

    Test::Exception::lives_ok { $client->promo_code("BOM2009") } "set promocode: BOM2009";
    is($client->promo_code, "BOM2009", "client promocode is: BOM2009");

    Test::Exception::lives_ok { $client->restricted_ip_address("192.168.0.1") } "set restricted_ip_address: 192.168.0.1";
    is($client->restricted_ip_address, "192.168.0.1", "client restricted_ip_address is: 192.168.0.1");

    Test::Exception::lives_ok {
        $client->save({
            'log'   => 0,
            'clerk' => 'test'
        });
    }
    "Can save all the changes back to the client";
};

my $open_account_details = {
    broker_code                   => 'CR',
    salutation                    => 'Ms',
    last_name                     => 'last-name',
    first_name                    => 'first-name',
    myaffiliates_token            => '',
    date_of_birth                 => '1979-01-01',
    citizen                       => 'au',
    residence                     => 'au',
    email                         => 'test@regentmarkets.com',
    address_line_1                => 'ADDR 1',
    address_line_2                => 'ADDR 2',
    address_city                  => 'Cyberjaya',
    address_state                 => 'State',
    address_postcode              => '55010',
    phone                         => '+60123456789',
    secret_question               => "Mother's maiden name",
    secret_answer                 => 'mei mei',
    myaffiliates_token_registered => 0,
    checked_affiliate_exposures   => 0,
    client_password               => '123456',
    binary_user_id                => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
    non_pep_declaration_time      => Date::Utility->new('20010108')->date_yyyymmdd,
    fatca_declaration_time        => Date::Utility->new('20010108')->date_yyyymmdd,
    fatca_declaration             => 1,

};

my $client;
subtest 'create client' => sub {
    Test::Exception::lives_ok {
        $client = $user->create_client(%$open_account_details)
    }
    "create new client success";
    my $new_loginid = $client->loginid;

    # Test save method
    $client = BOM::User::Client::get_instance({'loginid' => $new_loginid});
    $client->first_name('Amy');
    $client->last_name('mimi');
    $client->email('test@betonmarkets.com');
    Test::Exception::lives_ok { $client->save(); } "[save] call client save OK";

    BOM::User::Client::get_instance({'loginid' => $new_loginid});
    is($client->first_name,              "Amy",                   "[save] client first_name is: Amy");
    is($client->last_name,               "mimi",                  "[save] client last_name is: mimi");
    is($client->email,                   'test@betonmarkets.com', '[save] client email is: shuwnyuan@betonmarkets.com');
    is($client->aml_risk_classification, 'low',                   'by default risk classification is low for new client');
    throws_ok { $client->aml_risk_classification('dummy') }
    qr/Invalid aml_risk_classification/, $client->aml_risk_classification('standard');
    Test::Exception::lives_ok { $client->save(); } "[save] call client save OK";
    is($client->aml_risk_classification, 'standard', 'correct risk classification after update');

    $client->set_default_account('BTC');
    lives_ok { $client->set_payment_agent } 'No restriction on payment agent currency';
    ok $client->payment_agent, 'Client is payment agent now';
};

subtest 'Gender based on Salutation' => sub {
    my %gender_map = (
        Mr   => 'm',
        Ms   => 'f',
        Mrs  => 'f',
        Miss => 'f',
    );

    foreach my $salutation (keys %gender_map) {
        my %details = %$open_account_details;
        $details{salutation} = $salutation;
        $details{email}      = 'test+' . $salutation . '@binary.com';
        $details{first_name} = 'first-name-' . $salutation;

        $client = $user->create_client(%details);

        is($client->salutation, $salutation,              'Salutation: ' . $client->salutation);
        is($client->gender,     $gender_map{$salutation}, 'gender: ' . $client->gender);
    }
};

subtest 'no salutation, default Gender: m' => sub {
    foreach my $i (0 .. 1) {
        my %details = %$open_account_details;

        if ($i == 0) {
            $details{salutation} = '';
            note 'salutation = empty string';
        } else {
            delete $details{salutation};
            note 'salutation not exists';
        }

        $details{email}      = 'test++' . $i . '@binary.com';
        $details{first_name} = 'first-name-' . $i;
        $client              = $user->create_client(%details);

        is($client->salutation, '',  'Salutation: ' . $client->salutation);
        is($client->gender,     'm', 'default gender: m');
    }
};

subtest 'no salutation, set Gender explicitly' => sub {
    my %details = %$open_account_details;

    $details{salutation} = '';
    $details{gender}     = 'f';
    $details{email}      = 'test++ff@binary.com';
    $details{first_name} = 'first-name-ff';
    $client              = $user->create_client(%details);

    is($client->salutation, '',  'Salutation: ' . $client->salutation);
    is($client->gender,     'f', 'gender: ' . $client->gender);
};

subtest 'latest poi by' => sub {
    my $user = BOM::User->create(
        email    => 'latest+poi+by@deriv.com',
        password => 'cantgetitout'
    );

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $user->add_client($client_cr);

    my $tests = [{
            title  => 'Onfido + IDV, Onfido is more recent',
            onfido => {
                created_at => Date::Utility->new->_plus_years(1)->date_yyyymmdd,
            },
            idv => {
                requested_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            expected => 'onfido'
        },
        {
            title  => 'Onfido + IDV, IDV is more recent',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            idv => {
                requested_at => Date::Utility->new->_plus_years(1)->date_yyyymmdd,
            },
            expected => 'idv'
        },
        {
            title  => 'Only Onfido',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            idv      => undef,
            expected => 'onfido'
        },
        {
            title => 'Only IDV',
            idv   => {
                requested_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            onfido   => undef,
            expected => 'idv'
        },
        {
            title             => 'Only IDV - Pending',
            idv               => undef,
            idv_pending_check => 1,
            onfido            => undef,
            expected          => 'idv'
        },
        {
            title             => 'IDV - Pending but Onfido is more recent',
            idv               => undef,
            idv_pending_check => 1,
            onfido            => {
                created_at => Date::Utility->new->date_yyyymmdd,
            },
            expected => 'onfido'
        },
        {
            title    => 'none',
            idv      => undef,
            onfido   => undef,
            expected => undef,
        },
        {
            title  => 'Only Manual - Origin B.O.',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:01')->epoch,
                origin      => 'bo',
            },
            idv      => undef,
            onfido   => undef,
            expected => 'manual',
        },
        {
            title  => 'Only Manual - Origin Client',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:01')->epoch,
                origin      => 'client',
            },
            idv      => undef,
            onfido   => undef,
            expected => 'manual',
        },
        {
            title  => 'Manual and IDV, manual is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:01')->epoch,
                origin      => 'client',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            onfido   => undef,
            expected => 'manual',
        },
        {
            title  => 'Manual and IDV, IDV is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            idv => {
                requested_at => '2020-10-10 00:00:01',
            },
            onfido   => undef,
            expected => 'idv',
        },
        {
            title  => 'manual + Onfido, manual is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:01')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:00',
            },
            IDV      => undef,
            expected => 'manual',
        },
        {
            title  => 'manual + Onfido, onfido is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
            },
            idv      => undef,
            expected => 'onfido',
        },
        {
            title  => 'manual + Onfido + IDV, manual is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:01')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:00',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected => 'manual',
        },
        {
            title  => 'manual + Onfido + IDV, Onfido is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected => 'onfido',
        },
        {
            title  => 'manual + Onfido + IDV, Onfido is more recent (only verified)',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected      => 'idv',
            only_verified => 1,
        },
        {
            title  => 'manual + Onfido + IDV, Onfido is more recent (only verified, result=clear, not age_verified)',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'clear'
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected      => 'idv',
            only_verified => 1,
        },
        {
            title  => 'manual + Onfido + IDV, Onfido is more recent (only verified, result=clear, age_verified by Onfido)',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'system',
                reason     => 'by onfido'
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'clear'
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected      => 'onfido',
            only_verified => 1,
        },
        {
            title  => 'manual + Onfido + IDV, Onfido is more recent (only verified, result=clear, age verif by IDV)',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'system',
                reason     => 'by idv'
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'clear'
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected      => 'idv',
            only_verified => 1,
        },
        {
            title  => 'manual + Onfido + IDV, IDV is more recent',
            manual => {
                upload_date => Date::Utility->new('2020-10-10 00:00:00')->epoch,
                origin      => 'bo',
            },
            onfido => {
                created_at => '2020-10-10 00:00:00',
            },
            idv => {
                requested_at => '2020-10-10 00:00:01',
            },
            expected => 'idv',
        },
        # latest poi by for manual age verification
        {
            title            => 'LC:vanuatu, IDV verified, Onfido rejected, manual verified',
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'pepito',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'consider',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected        => 'manual',
            landing_company => 'vanuatu',
            lc_status       => 'verified',
        },
        # latest poi by for manual age verification counter example from system instead of BO staff
        {
            title            => 'LC:vanuatu, IDV verified, Onfido rejected, manual verified (by system)',
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'system',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'consider',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected        => 'onfido',
            landing_company => 'vanuatu',
            lc_status       => 'verified',
        },
        {
            title            => 'LC:svg, IDV verified, Onfido rejected, manual verified (by system)',
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'system',
            },
            onfido => {
                created_at => '2020-10-10 00:00:01',
                result     => 'consider',
            },
            idv => {
                requested_at => '2020-10-10 00:00:00',
            },
            expected        => 'onfido',
            landing_company => 'svg',
            lc_status       => 'verified',
        },
        {
            title => 'LC:maltainvest, only IDV (IDV not supported)',
            idv   => {
                requested_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            onfido          => undef,
            landing_company => 'maltainvest',
            expected        => undef,
            lc_status       => 'none',
        },
        {
            title  => 'LC:maltainvest, only Onfido',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
            },
            idv             => undef,
            landing_company => 'maltainvest',
            expected        => 'onfido',
            lc_status       => 'none',
        },
        {
            title  => 'LC:maltainvest, only Onfido-Verified',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
                result     => 'clear'
            },
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'system',
                reason     => 'by onfido'
            },
            idv             => undef,
            landing_company => 'maltainvest',
            expected        => 'onfido',
            lc_status       => 'verified',
        },
        {
            title  => 'LC:maltainvest, Onfido + IDV, Onfido wins even if IDV is more recent',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
                result     => 'consider',
            },
            idv => {
                requested_at => Date::Utility->new->_plus_years(1)->date_yyyymmdd,
            },
            landing_company => 'maltainvest',
            expected        => 'onfido',
            lc_status       => 'rejected',
        },
        {
            title  => 'LC:maltainvest, Onfido + manual',
            onfido => {
                created_at => Date::Utility->new->_minus_years(1)->date_yyyymmdd,
                result     => 'consider',
            },
            manual => {
                upload_date => Date::Utility->new->_plus_years(1)->epoch,
                origin      => 'bo',
            },
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'mr cat',
            },
            landing_company => 'maltainvest',
            expected        => 'manual',
            lc_status       => 'verified',
        },
        {
            title  => 'LC:maltainvest, Onfido + IDV + manual',
            onfido => {
                created_at => Date::Utility->new->_plus_years(1)->date_yyyymmdd,
                result     => 'consider',
            },
            manual => {
                upload_date => Date::Utility->new->_minus_years(1)->epoch,
                origin      => 'bo',
            },
            age_verification => {
                created_at => '2020-10-10 00:00:02',
                staff_name => 'mr cat',
            },
            idv => {
                requested_at => Date::Utility->new->_plus_years(2)->date_yyyymmdd,
            },
            landing_company => 'maltainvest',
            expected        => 'onfido',
            lc_status       => 'rejected',
        },
    ];

    my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
    my $manual_latest;
    $documents_mock->mock(
        'latest',
        sub {
            my ($self) = @_;

            $self->_clear_uploaded;

            return $manual_latest;
        });

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $onfido_latest;
    $onfido_mock->mock(
        'get_latest_check',
        sub {
            my (undef, $args) = @_;

            $args //= {};

            if ($args->{only_verified}) {
                if (($onfido_latest->{user_check}->{result} // '') ne 'clear') {
                    return {
                        user_check => undef,
                    };
                }
            }

            return $onfido_latest;
        });

    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    my $idv_latest;
    my $idv_pending_check;
    $idv_mock->mock(
        'get_last_updated_document',
        sub {
            if ($idv_latest || $idv_pending_check) {
                return {
                    binary_user_id  => $client->user->id,
                    document_type   => 'bvn',
                    issuing_country => 'ng',
                    document_number => '124124123412',
                    submitted_at    => '2020-10-10',
                    status          => $idv_latest ? 'verified' : 'pending',
                    id              => 1
                };
            }

            return undef;
        });
    $idv_mock->mock(
        'get_document_check_detail',
        sub {
            my (undef, $doc_id) = @_;

            return undef unless defined $idv_latest;

            return {
                document_id => $doc_id,
                status      => 'pending',
                $idv_latest->%*,
            };
        });

    my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
    my $age_verification_status;
    $status_mock->mock(
        'age_verification',
        sub {
            my ($self) = @_;

            $self->_build_all;

            return $age_verification_status;
        });

    for my $test ($tests->@*) {
        my ($onfido, $idv, $title, $expected, $manual, $idv_pending, $age_verification, $lc, $lc_status, $only_verified) =
            @{$test}{qw/onfido idv title expected manual idv_pending_check age_verification landing_company lc_status only_verified/};

        subtest $title => sub {
            invalidate_object_cache($client_cr);
            $age_verification_status = $age_verification;

            $onfido_latest = {user_check => $onfido};

            $idv_latest = $idv;

            $idv_pending_check = $idv_pending;

            $manual_latest = $manual;

            my $args = {
                only_verified   => $only_verified,
                landing_company => $lc // undef
            };

            my ($name, $check) = $client_cr->latest_poi_by($args);

            is $name, $expected, 'Expected POI subsystem reported';

            is $check, undef, 'Undef check' unless defined $expected;

            if ($idv_pending_check && $name eq 'idv') {
                is $check, undef, 'Expected undef check';
            } else {
                $expected //= '';
                isa_ok $check, 'HASH', 'Expected IDV check'    if $expected eq 'idv';
                isa_ok $check, 'HASH', 'Expected Onfido check' if $expected eq 'onfido';
            }

            if ($lc) {
                is $client_cr->get_poi_status({landing_company => $lc}), $lc_status, "Landing company $lc status is $lc_status";
            }
        };
    }
};

subtest 'is tin validated' => sub {
    my $CR_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $manual_mock = Test::MockModule->new('BOM::User::Client');
    $manual_mock->mock(
        'is_tin_manually_approved',
        sub {
            return 1;
        });

    ok $CR_client->is_tin_valid, 'TIN was manually approved by CS';

    $manual_mock->unmock_all();

    ok !$CR_client->is_tin_valid, 'TIN is undef';

    $CR_client->tax_identification_number('123');
    $CR_client->save();

    ok $CR_client->is_tin_valid, 'TIN passes for unregulated accounts';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code               => 'MF',
        residence                 => 'id',
        tax_residence             => 'id',
        place_of_birth            => 'id',
        tax_identification_number => '123'
    });

    my $financial_information = {
        "employment_industry" => "Finance",                # +15
        "education_level"     => "Secondary",              # +1
        "income_source"       => "Self-Employed",          # +0
        "net_income"          => '$25,000 - $50,000',      # +1
        "estimated_worth"     => '$100,000 - $250,000',    # +1
        "occupation"          => 'Managers',               # +0
        "employment_status"   => "Unemployed",             # +0
        "source_of_wealth"    => "Company Ownership",      # +0
        "account_turnover"    => 'Less than $25,000'
    };
    $client->financial_assessment({
        data => encode_json_utf8($financial_information),
    });
    $client->save();

    ok $client->is_tin_valid, 'TIN passes for specific employment statuses';

    $financial_information->{'employment_status'} = 'Self-Employed';
    $client->financial_assessment({
        data => encode_json_utf8($financial_information),
    });
    $client->save();

    $client->tax_identification_number('0000000000');
    $client->save();

    ok !$client->is_tin_valid, 'TIN invalid - random same number';

    $client->tax_identification_number('9999999999');
    $client->save();
    ok !$client->is_tin_valid, 'TIN invalid - random same number';

    $client->tax_identification_number('0123456789');
    $client->save();
    ok !$client->is_tin_valid, 'TIN invalid - number secuence asc order with 0';

    $client->tax_identification_number('9876543210');
    $client->save();
    ok !$client->is_tin_valid, 'TIN invalid - number secuence desc order with 0';

    $client->tax_identification_number('1234567');
    $client->save();
    ok !$client->is_tin_valid, 'TIN invalid - number secuence asc order';

    $client->tax_identification_number('98765');
    $client->save();
    ok !$client->is_tin_valid, 'TIN invalid - number secuence desc order';

    $client->tax_identification_number('167523958027836');
    $client->save();
    ok $client->is_tin_valid, 'TIN validated';

};

done_testing();

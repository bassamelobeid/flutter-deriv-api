use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Database::Model::OAuth;
use BOM::Platform::Account::Virtual;

use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;

use await;
use Data::Random qw(:all);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note',            sub { return 1 });
$client_mocked->mock('fully_authenticated', sub { return 1 });

my $t = build_wsapi_test();

my %client_details = (
    new_account_real          => 1,
    salutation                => 'Ms',
    last_name                 => 'last-name',
    first_name                => 'first\'name',
    date_of_birth             => '1990-12-30',
    residence                 => 'nl',
    place_of_birth            => 'de',
    address_line_1            => 'Jalan Usahawan',
    address_line_2            => 'Enterpreneur Center',
    address_city              => 'Cyberjaya',
    address_state             => 'Selangor',
    address_postcode          => '47120',
    phone                     => '+60321685000',
    secret_question           => 'Favourite dish',
    secret_answer             => 'nasi lemak,teh tarik',
    tax_residence             => 'de,nl',
    tax_identification_number => '111-222-333',
    account_opening_reason    => 'Speculative',
    citizen                   => 'at',
);

my $mf_details = {
    new_account_maltainvest => 1,
    accept_risk             => 1,
    account_opening_reason  => 'Speculative',
    address_line_1          => 'Test',
    %{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}};

subtest 'trying to create duplicate accounts' => sub {
    subtest 'create duplicate CR account' => sub {
        # Create first CR account

        # Create vr account
        my ($first_vr_client, $user) = create_vr_account({
            email           => 'unique+email@binary.com',
            residence       => 'af',
            client_password => 'abc123',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $first_vr_client->loginid);
        $t->await::authorize({authorize => $token});

        my %details = %client_details;
        $details{first_name} = rand_chars(
            set  => 'loweralpha',
            size => 15
        );
        $details{residence} = 'af';
        $details{phone}     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        # Create duplicate CR account
        my $second_vr_client;
        ($second_vr_client, $user) = create_vr_account({
            email           => 'unique2+email@binary.com',
            residence       => 'af',
            client_password => 'abc123',
        });

        $token = BOM::Database::Model::OAuth->new->store_access_token_only(1, $second_vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $res = $t->await::new_account_real(\%details, {timeout => 10});

        is($res->{msg_type}, 'new_account_real');
        is($res->{error}->{code}, 'DuplicateAccount', "Duplicate account detected correctly");
    };
};

subtest 'MLT upgrade to MF account' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+nl@binary.com',
        client_password => 'abc123',
        residence       => 'nl',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    my $mlt_loginid;
    subtest 'create MLT account, authorize' => sub {
        my $res = $t->await::new_account_real(\%client_details);
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        $mlt_loginid = $res->{new_account_real}->{client_id};
        like($mlt_loginid, qr/^MLT\d+$/, "got MLT client $mlt_loginid");

        ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_loginid);
        $t->await::authorize({authorize => $token});

        my $mlt_client = BOM::User::Client->new({loginid => $mlt_loginid});
        is($mlt_client->financial_assessment, undef, 'doesn\'t have financial assessment');

        $res = $t->await::get_settings({get_settings => 1});
        ok($res->{get_settings});
        is($res->{get_settings}->{address_line_1}, 'Jalan Usahawan', 'address line 1 set as expected');
        is($res->{get_settings}->{citizen},        'at',             'citizen set as expected');

    };

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        note explain %details;
        my $res = $t->await::new_account_maltainvest(\%details);
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);
        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = BOM::User::Client->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');
    };

};

subtest 'VR upgrade to MF - Germany' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+de@binary.com',
        client_password => 'abc123',
        residence       => 'de',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{first_name}                = 'first name DE';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);

        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = BOM::User::Client->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');

        is($client->place_of_birth, 'de',    'correct place of birth');
        is($client->tax_residence,  'de,nl', 'correct tax residence');
    };
};

subtest 'validate whitespace in required fields for maltainvest account' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test11+de@binary.com',
        client_password => 'abc123',
        residence       => 'de',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'validate whitespace in first_name' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{first_name}                = '    ';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',               "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: first_name', "Checked that validation failed for first_name");
    };

    subtest 'validate whitespace in last_name' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{last_name}                 = '    ';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',              "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: last_name', "Checked that validation failed for last_name");
    };

    subtest 'validate whitespace in tax_identification_number' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{tax_identification_number} = '    ';
        $details{first_name}                = 'John';
        $details{last_name}                 = 'Doe';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type}, 'new_account_maltainvest');
        is($res->{error}->{code}, 'InputValidationFailed', "Input field is invalid");
        is(
            $res->{error}->{message},
            'Input validation failed: tax_identification_number',
            "Checked that validation failed for tax_identification_number"
        );
    };

    subtest 'validate whitespace in address_line_1' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_line_1}            = '    ';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate non permitted chars in address_line_1' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_line_1}            = "~111";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate whitespace in address_city' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_city}              = '    ';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };

    subtest 'validate character count in address_city success' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_city}              = 'Taumatawhakatangihangakoauauotamateaturipukakapikimaungahoronukupokaiwhenuakitanatahu';
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type}, 'new_account_maltainvest');
        is($res->{error}->{code}, 'DuplicateAccount', "Input field is valid so it will fail for DuplicateAccount");
    };

    subtest 'validate character count in address_city failed' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_city} =
            "ThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLetters";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);
        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };
};

subtest 'unicode character test in required fields for maltainvest account' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test12+de@binary.com',
        client_password => 'abc123',
        residence       => 'de',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'validate unicode character in first_name' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{first_name}                = "%Shan^&tanu";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',               "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: first_name', "Checked that validation failed for first_name");
    };

    subtest 'validate unicode character in last_name' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{last_name}                 = "*P\$ti\@l";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',              "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: last_name', "Checked that validation failed for last_name");
    };

    subtest 'validate unicode character in address_line_1' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_line_1}            = "47\%Select*from Address";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate unicode character in address_city' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{address_city}              = "\%Cyber\%Jaya\%";
        $details{residence}                 = 'de';
        $details{phone}                     = '+442072343457';
        $details{tax_identification_number} = '11122233344';
        my $res = $t->await::new_account_maltainvest(\%details);
        test_schema('new_account_maltainvest', $res);

        is($res->{msg_type},         'new_account_maltainvest');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };
};

subtest 'CR client cannot upgrade to MF' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+id@binary.com',
        residence       => 'id',
        client_password => 'abc123',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'create CR acc, authorize' => sub {
        my %details = %client_details;
        $details{first_name} = 'first name ID';
        $details{residence}  = 'id';
        $details{phone}      = '+442072343457';

        my $res = $t->await::new_account_real(\%details);
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");

        ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
        $t->await::authorize({authorize => $token});
    };

    subtest 'CR cannot upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        my $res = $t->await::new_account_maltainvest(\%details);

        is($res->{msg_type},                'new_account_maltainvest');
        is($res->{error}->{code},           'PermissionDenied', "no MF upgrade for CR");
        is($res->{new_account_maltainvest}, undef,              'NO account created');
    };
};

subtest 'MX client can upgrade to MF' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+gb@binary.com',
        residence       => 'gb',
        client_password => 'abc123',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'create MX acc, authorize' => sub {
        my %details = %client_details;
        $details{first_name} = rand_chars(
            set  => 'loweralpha',
            size => 25
        );
        $details{residence} = 'gb';
        $details{phone}     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^MX\d+$/, "got MX client $loginid");

        ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
        $t->await::authorize({authorize => $token});

        subtest 'MX upgrade to MF' => sub {
            my %details = (%client_details, %$mf_details);
            $details{residence}                 = 'gb';
            $details{tax_identification_number} = '1112223334';
            delete $details{new_account_real};

            my $client = BOM::User::Client->new({loginid => $loginid});

            $res = $t->await::new_account_maltainvest(\%details);

            is($res->{msg_type}, 'new_account_maltainvest');
            is($res->{error}->{code}, undef, "MX upgrade to MF ok");
        };
    };
};

subtest 'validate whitespace in required fields for real account' => sub {

    # Create vr account
    my ($first_vr_client, $user) = create_vr_account({
        email           => 'myunique+email1@binary.com',
        residence       => 'af',
        client_password => 'abc123',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $first_vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'validate whitespace in first_name' => sub {

        my %details = %client_details;
        $details{first_name} = "   ";
        $details{residence}  = 'af';
        $details{phone}      = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',               "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: first_name', "Checked that validation failed for first_name");
    };

    subtest 'validate whitespace in last_name' => sub {

        my %details = %client_details;
        $details{last_name} = "   ";
        $details{residence} = 'af';
        $details{phone}     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',              "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: last_name', "Checked that validation failed for last_name");
    };

    subtest 'validate whitespace in address_line_1' => sub {

        my %details = %client_details;
        $details{address_line_1} = "   ";
        $details{residence}      = 'af';
        $details{phone}          = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate non permitted chars in address_line_1' => sub {

        my %details = %client_details;
        $details{address_line_1} = "~111";
        $details{residence}      = 'af';
        $details{phone}          = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate whitespace in address_city' => sub {

        my %details = %client_details;
        $details{address_city} = " ";
        $details{residence}    = 'af';
        $details{phone}        = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };

    subtest 'validate character count in address_city success' => sub {
        my %details = %client_details;
        $details{address_city} = "Taumatawhakatangihangakoauauotamateaturipukakapikimaungahoronukupokaiwhenuakitanatahu";
        $details{residence}    = 'af';
        $details{phone}        = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);
        is($res->{msg_type}, 'new_account_real');
        is($res->{error}->{code}, undef, "Input field is valid");
    };

    subtest 'validate character count in address_city error' => sub {
        my %details = %client_details;
        $details{address_city} =
            "ThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLettersThisIsACityNameWithMoreThanHundredLetters";
        $details{residence} = 'af';
        $details{phone}     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);
        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };

    subtest 'validate numbers in address_city at start' => sub {
        my %details = %client_details;
        $details{address_city} = "2Cyberjaya";
        $details{residence}    = 'af';
        $details{phone}        = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);
        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that city name should not contain a number");
    };

    subtest 'validate numbers in address_city everywhere else' => sub {
        my %details = %client_details;
        $details{address_city} = "Cyberjaya2";
        $details{residence}    = 'af';
        $details{phone}        = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);
        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that city name should not contain a number");
    };

    subtest 'validate whitespace in tax_identification_number' => sub {
        my %details = %client_details;
        $details{tax_identification_number} = "   ";
        $details{residence}                 = 'af';
        $details{phone}                     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);
        is($res->{msg_type}, 'new_account_real');
        is($res->{error}->{code}, 'InputValidationFailed', "Input field is invalid");
        is(
            $res->{error}->{message},
            'Input validation failed: tax_identification_number',
            "Checked that validation fails for tax_identification_number"
        );
    };
};

subtest 'unicode character test in required fields for real account' => sub {

    # Create vr account
    my ($first_vr_client, $user) = create_vr_account({
        email           => 'myunique+email2@binary.com',
        residence       => 'af',
        client_password => 'abc123',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $first_vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'validate unicode character in first_name' => sub {

        my %details = %client_details;
        $details{first_name} = "%Shan^&tanu";
        $details{residence}  = 'af';
        $details{phone}      = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',               "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: first_name', "Checked that validation failed for first_name");
    };

    subtest 'validate unicode character in last_name' => sub {

        my %details = %client_details;
        $details{last_name} = "*P\$ti\@l";
        $details{residence} = 'af';
        $details{phone}     = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',              "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: last_name', "Checked that validation failed for last_name");
    };

    subtest 'validate unicode character in address_line_1' => sub {

        my %details = %client_details;
        $details{address_line_1} = "47\%Select*from Address";
        $details{residence}      = 'af';
        $details{phone}          = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                   "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_line_1', "Checked that validation failed for address_line_1");
    };

    subtest 'validate unicode character in address_city' => sub {

        my %details = %client_details;
        $details{address_city} = "\%Cyber\%Jaya\%";
        $details{residence}    = 'af';
        $details{phone}        = '+4420'
            . rand_chars(
            set  => 'numeric',
            size => 8
            );
        my $res = $t->await::new_account_real(\%details, {timeout => 10});

        test_schema('new_account_real', $res);

        is($res->{msg_type},         'new_account_real');
        is($res->{error}->{code},    'InputValidationFailed',                 "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: address_city', "Checked that validation failed for address_city");
    };
};

subtest 'validate phone field' => sub {
    my %details = %client_details;
    $details{date_of_birth} = '1999-01-01';
    $details{residence}     = 'gb';
    $details{currency}  = 'USD';

    subtest 'phone can be empty' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'emptyness+222@binary.com',
            client_password => 'abC123',
            residence       => 'gb',
        });

        $details{first_name}    = 'i miss';
        $details{last_name}     = 'my phone number';
        $details{date_of_birth} = '1999-01-01';

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});
        delete $details{phone};

        my $res = $t->await::new_account_real(\%details);
        ok($res->{msg_type}, 'new_account_real');
        ok($res->{new_account_real});
    };

    subtest 'user can enter invalid or dummy phone number' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'dummy-phone-number@binary.com',
            client_password => 'abC123',
            residence       => 'gb',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{first_name}    = 'dummy-phone';
        $details{last_name}     = 'ownerian';
        $details{phone} = '+++1234-864116586523';

        my $res = $t->await::new_account_real(\%details);
        ok($res->{msg_type}, 'new_account_real');
        is($res->{error}, undef, 'account created successfully with a dummy phone number');
    };

    subtest 'no alphabetic characters are allowed in the phone number' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'alpha-phone-number@binary.com',
            client_password => 'abC123',
            residence       => 'gb',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{first_name}    = 'alphabetic';
        $details{last_name}     = 'phone-number';
        $details{phone} = '+++1234-86s4116586523'; # contains `s` in the middle

        my $res = $t->await::new_account_real(\%details);
        is($res->{error}->{code}, 'InvalidPhone', 'phone number can not contain alphabetic characters.');
    };
};

sub create_vr_account {
    my $args   = shift;
    my $params = {
        details        => {},
        email_verified => 1,
    };

    @{$params->{details}}{keys %$args} = values %$args;

    my $acc = BOM::Platform::Account::Virtual::create_account($params);

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;

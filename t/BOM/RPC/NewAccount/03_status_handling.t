use strict;
use warnings;

use Test::Mojo;
use Test::More;
use Test::Fatal qw(lives_ok);

use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::ProveID;
use BOM::Test::RPC::Client;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use Test::MockModule;

use BOM::Test::Helper::FinancialAssessment;

my ($rpc_ct, $t, $params);

_reset_params();

sub _reset_params {
    $params = {
        language => 'EN',
        source   => 1,
        country  => 'id',
        args     => {},
    };
}

sub new_client_details {
    my %given = @_;

    my %client_details = (
        salutation             => 'Mr',
        last_name              => 'test' . rand(999),
        first_name             => 'test' . rand(999),
        date_of_birth          => '1987-09-04',
        address_line_1         => 'test address_line_1',
        address_city           => 'test address_city',
        address_state          => 'test address_state',
        address_postcode       => 'test address_postcode',
        phone                  => sprintf("+15417555%03d", rand(999)),
        secret_question        => 'test secret_question',
        secret_answer          => 'test secret_answer',
        account_opening_reason => 'Speculative',
        citizen                => 'id',
        place_of_birth         => "id",
        residence              => "id",
    );

    return +{map { $_ => ($given{$_} // $client_details{$_}) } keys %client_details};
}

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

subtest 'MX' => sub {
    subtest 'Fail age verification' => sub {
        my $email = 'mx_fail_age@binary.com';

        my $verification_token = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{client_password}   = 'Abc123';
        $params->{args}->{verification_code} = $verification_token;
        $params->{args}->{residence}         = 'gb';

        my $result = $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('Virtual account created')->result;
        my $loginid = $result->{client_id};

        my $vr_client = BOM::User::Client->new({loginid => $loginid});

        ok($vr_client->status->unwelcome, 'gb virtual account unwelcome on creation');

        _reset_params();

        $params->{token} = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
        $params->{args} = new_client_details(residence => 'gb');

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianInsufficientDOB.xml";

        my $proveid_mock = Test::MockModule->new('BOM::Platform::ProveID');
        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $result = $rpc_ct->call_ok("new_account_real", $params)->has_no_system_error->has_no_error('Real account created')->result;
        $loginid = $result->{client_id};

        my $mx_client = BOM::User::Client->new({loginid => $loginid});
        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});

        ok($mx_client->status->unwelcome, 'Unwelcome on creation');
        ok($vr_client->status->unwelcome, 'Virtual remains unwelcome');
    };

    subtest 'Pass age verification' => sub {
        my $email = 'mx_pass_age@binary.com';

        _reset_params();

        my $verification_token = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{client_password}   = 'Abc123';
        $params->{args}->{verification_code} = $verification_token;
        $params->{args}->{residence}         = 'gb';

        my $result = $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('Virtual account created')->result;
        my $loginid = $result->{client_id};

        my $vr_client = BOM::User::Client->new({loginid => $loginid});

        ok($vr_client->status->unwelcome, 'gb virtual account unwelcome on creation');

        _reset_params();

        $params->{token} = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
        $params->{args} = new_client_details(residence => 'gb');

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianValid.xml";

        my $proveid_mock = Test::MockModule->new('BOM::Platform::ProveID');
        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $result = $rpc_ct->call_ok("new_account_real", $params)->has_no_system_error->has_no_error('Real account created')->result;
        $loginid = $result->{client_id};
        my $mx_client = BOM::User::Client->new({loginid => $loginid});

        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});

        ok(!$mx_client->status->unwelcome, 'Account not unwelcome on creation');
        ok(!$vr_client->status->unwelcome, 'Virtual no longer unwelcome');
    };
};

subtest 'MF' => sub {
    my $email = 'mf@binary.com';

    _reset_params();

    my $verification_token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $params->{args}->{client_password}   = 'Abc123';
    $params->{args}->{verification_code} = $verification_token;
    $params->{args}->{residence}         = 'es';                  # es(Spain) only has MF as a landing company

    my $result = $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('Virtual account created')->result;

    my $loginid = $result->{client_id};

    my $vr_client = BOM::User::Client->new({loginid => $loginid});

    ok(!$vr_client->status->unwelcome, 'virtual account not unwelcome on creation');

    _reset_params();

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
    $params->{args} = new_client_details(residence => 'es');

    # MF needs additional arguments to create
    $params->{args}->{accept_risk}               = 1;
    $params->{args}->{tax_residence}             = 'es';
    $params->{args}->{tax_identification_number} = 12314124;
    my $fa = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $params->{args}->{$_} = $fa->{$_} for keys %$fa;

    $result = $rpc_ct->call_ok("new_account_maltainvest", $params)->has_no_system_error->has_no_error('Real account created')->result;
    $loginid = $result->{client_id};

    my $mf_client = BOM::User::Client->new({loginid => $loginid});
    $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});

    ok($mf_client->status->unwelcome,  'Account unwelcome on creation');
    ok(!$vr_client->status->unwelcome, 'Virtual account not unwelcome');

};

subtest 'CR' => sub {
    my $email = 'cr@binary.com';

    _reset_params();

    my $verification_token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $params->{args}->{client_password}   = 'Abc123';
    $params->{args}->{verification_code} = $verification_token;
    $params->{args}->{residence}         = 'id';

    my $result = $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('Virtual account created')->result;

    my $loginid = $result->{client_id};

    my $vr_client = BOM::User::Client->new({loginid => $loginid});

    ok(!$vr_client->status->unwelcome, 'virtual account not unwelcome on creation');

    _reset_params();

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
    $params->{args} = new_client_details(residence => 'id');
    $result = $rpc_ct->call_ok("new_account_real", $params)->has_no_system_error->has_no_error('Real account created')->result;
    $loginid = $result->{client_id};

    my $cr_client = BOM::User::Client->new({loginid => $loginid});
    $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});

    ok(!$cr_client->status->unwelcome, 'Account not unwelcome on creation');
    ok(!$vr_client->status->unwelcome, 'virtual account not unwelcome on creation');
};

subtest 'MLT' => sub {
    my $email = 'mlt@binary.com';

    _reset_params();

    my $verification_token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $params->{args}->{client_password}   = 'Abc123';
    $params->{args}->{verification_code} = $verification_token;
    $params->{args}->{residence}         = 'be';

    my $result = $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('Virtual account created')->result;

    my $loginid = $result->{client_id};

    my $vr_client = BOM::User::Client->new({loginid => $loginid});

    ok(!$vr_client->status->unwelcome, 'virtual account not unwelcome on creation');

    _reset_params();

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_client->loginid, 'test token');
    $params->{args} = new_client_details(residence => 'be');
    $result = $rpc_ct->call_ok("new_account_real", $params)->has_no_system_error->has_no_error('Real account created')->result;
    $loginid = $result->{client_id};

    my $mlt_client = BOM::User::Client->new({loginid => $loginid});
    $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});

    ok(!$mlt_client->status->unwelcome, 'Account not unwelcome on creation');
    ok(!$vr_client->status->unwelcome,  'virtual account not unwelcome on creation');
};

done_testing();

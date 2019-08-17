use strict;
use warnings;

use Email::Sender::Transport::Test;
use Test::Most 'no_plan';
use Test::FailWarnings;
use File::Spec;
use Test::MockModule;
use Test::Exception;

use BOM::Platform::Email;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';

use BOM::User::Client;
use BOM::Platform::ProveID;
use BOM::Platform::Context qw(request);
use BOM::Platform::Client::IDAuthentication;

use BOM::Test::Helper::Client qw(create_client);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $xml              = XML::Simple->new;
my $support_email    = 'support@binary.com';
my $compliance_email = 'compliance@binary.com';
my $password         = 'Abc123';
my $hash_pwd         = BOM::User::Password::hashpw($password);

sub email_list {
    my $transport = Email::Sender::Simple->default_transport;
    my @emails = map { +{$_->{envelope}->%*, subject => '' . $_->{email}->get_header('Subject'),} } $transport->deliveries;
    $transport->clear_deliveries;
    @emails;
}

subtest 'Constructor' => sub {
    subtest 'No Client' => sub {
        throws_ok(sub { BOM::Platform::Client::IDAuthentication->new() }, qr/Missing required arguments: client/, "Constructor dies with no client");
    };
    subtest 'With Client' => sub {
        my $c = create_client();
        my $obj = BOM::Platform::Client::IDAuthentication->new({client => $c});
        isa_ok($obj, "BOM::Platform::Client::IDAuthentication", "Constructor ok with client");
    };
};

subtest 'Virtual accounts' => sub {
    my $c = create_client('VRTC');

    my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
    ok !$v->client->is_first_deposit_pending, 'No tracking of first deposit for virtual accounts';
    is($v->run_authentication, undef, "run_authentication for VRTC ok");

};
subtest "CR accounts" => sub {
    my $c = create_client("CR");

    my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
    ok $v->client->is_first_deposit_pending, 'First deposit tracking for CR account';

    $v->run_authentication();

    ok !$v->client->status->cashier_locked, "CR client not cashier locked following run_authentication";
    ok !$v->client->status->unwelcome,      "CR client not unwelcome following run_authentication";
};

subtest 'MLT accounts' => sub {
    subtest 'Not age verified prior to run_authentication' => sub {
        my $c = create_client('MLT');
        $c->status->clear_age_verification;

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MLT account';

        $v->run_authentication;

        ok !$v->client->fully_authenticated, 'Not fully authenticated';
        ok !$v->client->status->age_verification, 'Not age verified';
        ok !$v->client->status->unwelcome,        'Not unwelcome';
        ok $v->client->status->cashier_locked, 'Cashier_locked';
    };
    subtest 'Age verified prior to run_authentication' => sub {
        my $c = create_client('MLT');

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MLT account';

        $v->client->status->set("age_verification");

        $v->run_authentication;

        ok !$v->client->fully_authenticated, 'Not fully authenticated';
        ok !$v->client->status->unwelcome,      'Not unwelcome';
        ok !$v->client->status->cashier_locked, 'Not cashier_locked';
    };
};

subtest 'MF accounts' => sub {
    subtest "Not authenticated prior to run_authentication" => sub {
        my $c = create_client('MF');

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MF account';

        $c->set_authentication('ID_DOCUMENT')->status('pending');

        $v->run_authentication;

        ok !$v->client->fully_authenticated, 'Not fully authenticated';
        ok $v->client->status->unwelcome, "Unwelcome";
    };
    subtest "Authenticated prior to run_authentication" => sub {
        my $c = create_client('MF');

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MF account';

        $c->set_authentication('ID_DOCUMENT')->status('pass');

        $v->run_authentication;

        ok $v->client->fully_authenticated, 'Fully authenticated';
        ok !$v->client->status->unwelcome, "Not unwelcome";
    };
};

my $emails = {};

subtest 'MX accounts' => sub {
    my $mock         = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
    my $proveid_mock = Test::MockModule->new('BOM::Platform::ProveID');

    my $brand = request()->brand;

    $mock->mock(
        send_email => sub {
            _send_email(shift);
        });

    $mock->mock(
        _notify_cs => sub {
            my $self    = shift;
            my $subject = shift;

            return _send_email({
                to      => $support_email,
                subject => $subject
            });
        });
    subtest 'Non-gb residence' => sub {

        my $c = create_client('MX', undef, {residence => 'de'});

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c)->proveid;
        is($v, undef, "run_authentication for Non-gb residence ok");

    };
    subtest "Invalid ProveID Matches" => sub {
        my $base_dir = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/";
        my @invalid_matches = ("ExperianDeceased", "ExperianOFSI", "ExperianPEP", "ExperianBOE");

        for my $match (@invalid_matches) {
            subtest "$match" => sub {
                my ($vr_client, $mx_client) =
                    @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_' . $match . '@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

                $vr_client->status->set('unwelcome', 'system', 'test');

                my $loginid      = $mx_client->loginid;
                my $client_email = $mx_client->email;
                $emails = {};

                my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);

                my $file_path = $base_dir . $match . ".xml";

                $proveid_mock->mock(
                    get_result => sub {
                        open my $fh, '<', $file_path;
                        read $fh, my $file_content, -s $fh;
                        return $file_content;
                    });
                $v->run_validation('signup');

                ok $v->client->status->disabled,          "Disabled due to $match";
                ok $v->client->status->proveid_requested, "ProveID requested";

                $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});
                ok $vr_client->status->unwelcome, "VR still unwelcomed";

                is($emails->{$support_email}, "Account $loginid disabled following Experian results", "CS received email");
                is($emails->{$client_email},  "Documents are required to verify your identity",       "Client received email");
            };
        }
    };
    subtest "Insufficient DOB Match in ProveID" => sub {
        my ($vr_client, $mx_client) = @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_lowdob@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

        $vr_client->status->set('unwelcome', 'system', 'test');

        my $loginid      = $mx_client->loginid;
        my $client_email = $mx_client->email;
        $emails = {};

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianInsufficientDOB.xml";

        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $v->run_validation('signup');

        ok !$v->client->status->disabled, "Not disabled due to Insufficient DOB Match";
        ok $v->client->status->unwelcome,         "Unwelcome due to Insufficient DOB Match";
        ok $v->client->status->proveid_requested, "ProveID requested";

        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});
        ok $vr_client->status->unwelcome, "VR still unwelcomed";

        is($emails->{$client_email}, "Documents are required to verify your identity", "Client received email");
    };
    subtest "Sufficient DOB, Sufficient UKGC" => sub {
        my ($vr_client, $mx_client) =
            @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_highdob_ukgc@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

        $vr_client->status->set('unwelcome', 'system', 'test');

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianValid.xml";

        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $v->run_validation('signup');

        ok !$v->client->status->disabled,  "Not disabled due to sufficient DOB Match";
        ok !$v->client->status->unwelcome, "Not unwelcome due to sufficient FullNameAndAddress Match";
        ok $v->client->status->age_verification,   "Age verified due to suffiecient DOB Match";
        ok $v->client->status->ukgc_authenticated, "UKGC authenticated due to sufficient FullNameAndAddress Match";
        ok $v->client->status->proveid_requested,  "ProveID requested";

        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});
        ok !$vr_client->status->unwelcome, "VR welcomed";
    };

    subtest "Sufficient DOB, Insufficient UKGC" => sub {
        my ($vr_client, $mx_client) =
            @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_highdob_no_ukgc@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

        $vr_client->status->set('unwelcome', 'system', 'test');

        my $loginid = $mx_client->loginid;

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianInsufficientUKGC.xml";

        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $v->run_validation('signup');
        ok !$v->client->status->disabled, "Not disabled due to Insufficient DOB Match";
        ok $v->client->status->unwelcome, "Unwelcome due to insufficient DOB Match";
        ok !$v->client->status->ukgc_authenticated, "Not ukgc authenticated due to insufficient FullNameAndAddress match";
        ok $v->client->status->proveid_requested, "ProveID requested";

        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});
        ok !$vr_client->status->unwelcome, "VR welcomed";

    };
    subtest "No Experian entry found" => sub {
        subtest "Error 501" => sub {
            my ($vr_client, $mx_client) =
                @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_no_entry@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

            $vr_client->status->set('unwelcome', 'system', 'test');

            my $loginid      = $mx_client->loginid;
            my $client_email = $mx_client->email;
            $emails = {};

            my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);
            $proveid_mock->mock(
                get_result => sub {
                    die '501: No Match Found';
                });
            $v->run_validation('signup');

            ok !$v->client->status->disabled, "Not disabled due to no entry";
            ok $v->client->status->unwelcome,         "Unwelcome due to no entry";
            ok $v->client->status->proveid_requested, "ProveID requested";

            is($emails->{$client_email}, "Documents are required to verify your identity", "Client received email");
        };
        subtest "Blank Response" => sub {
            my ($vr_client, $mx_client) = @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_blank@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

            $vr_client->status->set('unwelcome', 'system', 'test');

            my $loginid      = $mx_client->loginid;
            my $client_email = $mx_client->email;
            $emails = {};

            my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);

            my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianBlank.xml";

            $proveid_mock->mock(
                get_result => sub {
                    open my $fh, '<', $file_path;
                    read $fh, my $file_content, -s $fh;
                    return $file_content;
                });

            $v->run_validation('signup');

            ok !$v->client->status->disabled, "Not disabled due to no entry";
            ok $v->client->status->unwelcome,         "Unwelcome due to no entry";
            ok $v->client->status->proveid_requested, "ProveID requested";

            is($emails->{$client_email}, "Documents are required to verify your identity", "Client received email");
        };
    };
    subtest "Error connecting to Experian" => sub {
        my ($vr_client, $mx_client) =
            @{create_user_and_clients(['VRTC', 'MX'], 'mx_test_connection_error@binary.com', {residence => 'gb'})}{'VRTC', 'MX'};

        $vr_client->status->set('unwelcome', 'system', 'test');

        my $loginid = $mx_client->loginid;

        $emails = {};

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $mx_client);
        $proveid_mock->mock(
            get_result => sub {
                die "Test Error";
            });

        warning_like { $v->run_validation('signup'); } qr/^$loginid signup validation proveid fail:/, "ProveID fails correctly";

        ok !$v->client->status->disabled, "Not disabled due to failed request";
        ok $v->client->status->unwelcome,         "Unwelcome due to failed request";
        ok $v->client->status->proveid_requested, "ProveID requested";
        ok $v->client->status->proveid_pending,   "ProveID flag for retry set";

        $vr_client = BOM::User::Client->new({loginid => $vr_client->loginid});
        ok $vr_client->status->unwelcome, "VR still unwelcomed";

        is($emails->{$compliance_email}, "Experian request error for client $loginid", "CS received email");
    };
};

sub _send_email {
    my $args = shift;
    my $to   = $args->{to};
    my $subj = $args->{subject};

    $emails->{$to} = $subj;
    return 1;
}

sub create_user_and_clients {
    my $brokers = shift;
    my $email   = shift;
    my $details = shift;

    my $user = BOM::User->create(
        email => $email // 'mx_test' . rand(999) . '@binary.com',
        password => $hash_pwd
    );

    my $clients = {};

    for my $broker (@$brokers) {
        my $c = create_client($broker, undef, $details);
        $clients->{$broker} = $c;
        $user->add_client($c);
    }

    return $clients;
}

1;

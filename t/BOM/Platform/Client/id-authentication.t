use Test::Most 'no_plan';
use Test::FailWarnings;
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Brands;
use BOM::User::Client;
use Email::Folder::Search;
use BOM::Platform::ProveID;
use BOM::Platform::Context qw(request);
use BOM::Test::Helper::Client qw(create_client);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Platform::Client::IDAuthentication;

my $xml              = XML::Simple->new;
my $support_email    = 'support@binary.com';
my $compliance_email = 'compliance@binary.com';

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

    my $brand = Brands->new(name => request()->brand);

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

    subtest "Invalid ProveID Matches" => sub {
        my $base_dir = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/";
        my @invalid_matches = ("ExperianFraud", "ExperianDeceased", "ExperianOFSI", "ExperianPEP", "ExperianBOE");

        for my $match (@invalid_matches) {
            subtest "$match" => sub {
                my $c = create_client('MX');

                my $loginid      = $c->loginid;
                my $client_email = $c->email;
                $emails = {};

                my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);

                my $file_path = $base_dir . $match . ".xml";

                $proveid_mock->mock(
                    get_result => sub {
                        open my $fh, '<', $file_path;
                        read $fh, my $file_content, -s $fh;
                        return $file_content;
                    });
                $v->run_authentication;

                ok $v->client->status->disabled,          "Disabled due to $match";
                ok $v->client->status->proveid_requested, "ProveID requested";

                is($emails->{$support_email}, "Account $loginid disabled following Experian results", "CS received email");
                is($emails->{$client_email},  "Documents are required to verify your identity",       "Client received email");
            };
        }
    };
    subtest "Insufficient DOB Match in ProveID" => sub {
        my $c = create_client('MX');

        my $loginid      = $c->loginid;
        my $client_email = $c->email;
        $emails = {};

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianInsufficientDOB.xml";

        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $v->run_authentication;

        ok !$v->client->status->disabled, "Not disabled due to Insufficient DOB Match";
        ok $v->client->status->unwelcome,         "Unwelcome due to Insufficient DOB Match";
        ok $v->client->status->proveid_requested, "ProveID requested";

        is($emails->{$support_email}, "Account $loginid unwelcome following Experian results", "CS received email");
        is($emails->{$client_email},  "Documents are required to verify your identity",        "Client received email");
    };
    subtest "Sufficient DOB Match in ProveID" => sub {
        my $c = create_client('MX');

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);

        my $file_path = "/home/git/regentmarkets/bom-test/data/Experian/SavedXML/ExperianValid.xml";

        $proveid_mock->mock(
            get_result => sub {
                open my $fh, '<', $file_path;
                read $fh, my $file_content, -s $fh;
                return $file_content;
            });

        $v->run_authentication;

        ok !$v->client->status->disabled,  "Not disabled due to sufficient DOB Match";
        ok !$v->client->status->unwelcome, "Not welcome due to sufficient DOB Match";
        ok $v->client->status->age_verification,  "Age verified due to suffiecient DOB Match";
        ok $v->client->status->proveid_requested, "ProveID requested";
    };
    subtest "No Experian entry found" => sub {
        my $c = create_client('MX');

        my $loginid      = $c->loginid;
        my $client_email = $c->email;
        $emails = {};

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        $proveid_mock->mock(
            get_result => sub {
                die 'Experian XML Request Failed with ErrorCode: 501, ErrorMessage: No Match Found';
            });

        $v->run_authentication;

        ok !$v->client->status->disabled, "Not disabled due to no entry";
        ok $v->client->status->unwelcome,         "Unwelcome due to no entry";
        ok $v->client->status->proveid_requested, "ProveID requested";

        is($emails->{$support_email}, "Account $loginid unwelcome due to lack of entry in Experian database", "CS received email");
        is($emails->{$client_email}, "Documents are required to verify your identity", "Client received email");
    };
    subtest "Error connecting to Experian" => sub {
        my $c = create_client('MX');

        my $loginid = $c->loginid;
        $emails = {};

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        $proveid_mock->mock(
            get_result => sub {
                die "Test Error";
            });

        $v->run_authentication;

        ok !$v->client->status->disabled, "Not disabled due to failed request";
        ok $v->client->status->unwelcome,         "Unwelcome due to failed request";
        ok $v->client->status->proveid_requested, "ProveID requested";
        ok $v->client->status->proveid_pending,   "ProveID flag for retry set";

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

1;

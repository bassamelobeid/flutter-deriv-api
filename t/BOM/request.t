use Test::Most;
use Test::MockModule;
use Path::Tiny;
use Encode;
use BOM::Backoffice::Form;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Auth    qw(get_staff_nickname);

subtest 'Unicode requests' => sub {

    my %input;
    my @blns = grep { $_ !~ /^#/ } path("/home/git/regentmarkets/bom-backoffice/t/blns.txt")->lines({chomp => 1});
    for (0 .. @blns) { $input{$_} = $blns[$_] if $blns[$_] }

    my $mock_cgi = Test::MockModule->new('CGI');
    $mock_cgi->mock(
        'param',
        sub {
            my ($self, $p) = @_;
            return $p ? Encode::encode('UTF-8', $input{$p}) : keys %input;
        });

    my $mock_request = Test::MockModule->new('BOM::Backoffice::Request::Base');
    $mock_request->mock('cgi',         sub { return CGI->new; });
    $mock_request->mock('http_method', sub { return ''; });

    my %output = %{request()->params};
    cmp_ok $output{$_}, 'eq', $input{$_} for (keys %input);
};

subtest 'get_csrf_token' => sub {

    throws_ok { BOM::Backoffice::Form::get_csrf_token() } qr/Can't find auth token/, "Can't find auth token";

    my $mock_request = Test::MockModule->new('BOM::Backoffice::Request::Base');
    $mock_request->mock('cookies', sub { return {auth_token => 'dummy'} });

    my $csrf_token = BOM::Backoffice::Form::get_csrf_token();
    is $csrf_token , '476940fb1c4c3d90ed7c959fedaefd9945808e2605bed65e87c0a9e3f3cb0392', 'csrf_token matches';

};

subtest 'get_staff_nickname' => sub {
    my $staff = {
        'issuer'         => 'https://derivcom.cloudflareaccess.com',
        'id'             => 'he200958-5b36-4368-2057-4842f23d7fd0',
        'identity_nonce' => 'rejq7GVraGnLUtqy',
        'details'        => {
            'email'             => 'test_name@regentmarkets.com',
            'backofficeauth0ID' => '',
            'group'             => [],
            'name'              => 'test name'
        },
        'country' => 'AE',
        'name'    => 'test name',
        'expiry'  => 1695803758,
        'email'   => 'test_name@regentmarkets.com'
    };
    is BOM::Backoffice::Auth::get_staff_nickname($staff), 'test_name', 'get_staff_nickname matches';
    ok BOM::Backoffice::Auth::get_staff_nickname($staff) ne 'test name',    'get_staff_nickname not match';
    ok BOM::Backoffice::Auth::get_staff_nickname($staff) ne 'test name123', 'get_staff_nickname not match';
    $staff->{email} = '';
    is BOM::Backoffice::Auth::get_staff_nickname($staff), 'test name', 'get_staff_nickname matches';
    ok BOM::Backoffice::Auth::get_staff_nickname($staff) ne 'test_name',    'get_staff_nickname not match';
    ok BOM::Backoffice::Auth::get_staff_nickname($staff) ne 'test_name234', 'get_staff_nickname not match';
};

done_testing;


use strict;
use warnings;

use Date::Utility;
use Test::More;
use Test::MockModule;
use Test::Fatal;

use Brands;

use BOM::Platform::Client::Sanctions;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $sanction_result = {
    matched => 1,
    list    => 'test list',
    name    => 'test name',
    reason  => 'test  reason',
};
my $mock_sanctions = Test::MockModule->new('Data::Validate::Sanctions');
$mock_sanctions->redefine(get_sanctioned_info => sub { return $sanction_result });

my $email_args;
my $mock_email = Test::MockModule->new('BOM::Platform::Client::Sanctions');
$mock_email->redefine(
    send_email => sub {
        $email_args = shift;
    });

my $brand     = Brands->new(name => 'deriv');
my $client    = create_client('CR');
my $client_vr = create_client('VRTC');
my $result;

subtest 'Validations' => sub {
    like exception { BOM::Platform::Client::Sanctions->new() }, qr/Attribute \(brand\) is required at constructor/, 'Missing brand exception';

    like exception { BOM::Platform::Client::Sanctions->new(brand => 'bcd') },
        qr/\QAttribute (brand) does not pass the type constraint/, 'Invalid brand type';

    like exception { BOM::Platform::Client::Sanctions->new(brand => $brand) },
        qr/\QAttribute (client) is required at constructor/, 'Missing client exception';

    like exception { BOM::Platform::Client::Sanctions->new(brand => $brand) },
        qr/\QAttribute (client) is required at constructor/, 'Missing client exception';

    like exception { BOM::Platform::Client::Sanctions->new(brand => $brand, client => 'abcd') },
        qr/\QAttribute (client) does not pass the type constraint/, 'Invalid client type';

    ok(
        BOM::Platform::Client::Sanctions->new(
            brand  => $brand,
            client => $client
        ),
        'Sanctions object is created successfully'
    );

};

subtest 'Account types and broker codes' => sub {
    for my $broker (qw(CR MLT MF MX)) {
        $sanction_result->{matched} = 0;
        undef $email_args;

        my $cl = create_client($broker);
        $cl->set_authentication('ID_DOCUMENT')->status('pending');
        my $checker = BOM::Platform::Client::Sanctions->new(
            client => $cl,
            brand  => $brand
        );

        is $checker->check(), undef, "result is empty when no match is found - $broker";
        is $email_args, undef, 'No email is sent - $broker';

        $sanction_result->{matched} = 1;
        is $checker->check(), 'test list', "matched list is reutrned - $broker";
        test_sanctions_email($cl);
        undef $email_args;

        $checker = BOM::Platform::Client::Sanctions->new(
            client     => $cl,
            brand      => $brand,
            skip_email => 1
        );
        is $checker->check(), 'test list', "matched list is reutrned - $broker";
        is $email_args, undef, 'Email is skipped - $broker';

        #authenticate the client
        $checker = BOM::Platform::Client::Sanctions->new(
            client => $cl,
            brand  => $brand
        );
        $cl->set_authentication('ID_DOCUMENT')->status('pass');
        is $checker->check(), undef, "result is empty when if client is authenticated by default - $broker";
        is $email_args, undef, 'No email is sent for authenticated clients by default - $broker';

        # recheck_authentication option
        $checker = BOM::Platform::Client::Sanctions->new(
            client                        => $cl,
            brand                         => $brand,
            recheck_authenticated_clients => 1
        );
        is $checker->check(), 'test list', "result is empty when if client is authenticated by default - $broker";
        test_sanctions_email($cl);
        undef $email_args;
    }

    $result = BOM::Platform::Client::Sanctions->new(
        client => $client_vr,
        brand  => $brand
    )->check();
    is $result , undef, 'Sanction check is  skipped for virtual accounts';
    is $email_args, undef, 'No email is sent';
};

subtest 'Arguments' => sub {
    my $checker = BOM::Platform::Client::Sanctions->new(
        client => $client,
        brand  => $brand
    );
    is $checker->check(comments => 'test comment'), 'test list', 'Test result is correct';
    test_sanctions_email($client, 'test comment');

    is $checker->check(
        comments     => 'test comment',
        triggered_by => 'MT5 signup'
        ),
        'test list', 'Test result is correct';
    test_sanctions_email($client, 'test comment', 'MT5 signup');
};

sub test_sanctions_email {
    my ($client, $comment, $triggered_by) = @_;
    my $loginid = $client->loginid;
    my $name    = join(' ', $client->first_name, $client->last_name);

    my $expected_subject = "$loginid possible match in sanctions list";
    $expected_subject .= " - $triggered_by" if $triggered_by;

    is $email_args->{from}, $brand->emails('system'),     'Sending email address is corect';
    is $email_args->{to},   $brand->emails('compliance'), 'Receiving email address is corect';
    is $email_args->{subject}, $expected_subject, 'Emain subject is correct';
    like $email_args->{message}->[0], qr($loginid.*$name.*\n.*$sanction_result->{list}), 'Email body is correct';
    is $email_args->{message}->[1], $comment // '', 'Email comments are correct';
}

$mock_sanctions->unmock_all;
$mock_email->unmock_all;

done_testing();


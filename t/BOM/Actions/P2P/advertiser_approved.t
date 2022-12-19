use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::User;
use BOM::Test::Email;
use BOM::Event::Actions::P2P;
use BOM::Event::Process;

BOM::Test::Helper::P2P::bypass_sendbird();

my $mock_emitter = new Test::MockModule('BOM::Platform::Event::Emitter');
my $mock_segment = new Test::MockModule('WebService::Async::Segment::Customer');

my (@track_events, @track_args);

$mock_emitter->redefine(
    'emit' => sub {
        my ($track_event, $args) = @_;
        push @track_events,
            {
            event => $track_event,
            args  => $args
            };
    });

$mock_segment->redefine(
    'track' => sub {
        my ($customer, %args) = @_;
        push @track_args, \%args;
        return Future->done(1);
    });

my $client                          = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $advertiser_approved_track_event = 'p2p_advertiser_approved';

BOM::User->create(
    email    => $client->email,
    password => 'xxx',
)->add_client($client);
$client->account('USD');

$client->status->set('allow_document_upload', 'system', 'manually set');

mailbox_clear();
undef @track_args;
undef @track_events;
BOM::Event::Actions::P2P::p2p_advertiser_approval_changed({client => $client});
my $msg = mailbox_search(to => $client->email);

is $msg,                                    undef, 'no email sent if client has allow_document_upload for other reason';
is scalar @track_args + scalar @track_args, 0,     'no track events sent';

$client->status->clear_allow_document_upload;
$client->status->set('allow_document_upload', 'system', 'P2P_ADVERTISER_CREATED');

mailbox_clear();
undef @track_args;
undef @track_events;
BOM::Event::Actions::P2P::p2p_advertiser_approval_changed({client_loginid => $client->loginid});
$msg = mailbox_search(to => $client->email);

is $msg,                                      undef, 'no email sent if client is not approved';
is scalar @track_args + scalar @track_events, 0,     'no track events sent';

$client->status->set('age_verification', 'system', 'manually set');
$client->p2p_advertiser_create(name => 'bob');

mailbox_clear();
undef @track_events;
BOM::Event::Actions::P2P::p2p_advertiser_approval_changed({client_loginid => $client->loginid});
$msg = mailbox_search(to => $client->email);

is $msg->{subject},      'You can now use Deriv P2P', 'email received - subject';
is scalar @track_events, 1,                           'track event sent';
my $event = $track_events[0];
is $event->{event},           $advertiser_approved_track_event, 'event emitted - event name';
is $event->{args}->{loginid}, $client->loginid,                 'event emitted - loginid';

undef @track_args;
BOM::Event::Process->new(category => 'track')->process({
        type    => $advertiser_approved_track_event,
        details => {loginid => $client->loginid}})->get;
my $track_event = $track_args[0];
is $track_event->{properties}{loginid}, $client->loginid, 'event fired - loginid';

done_testing();

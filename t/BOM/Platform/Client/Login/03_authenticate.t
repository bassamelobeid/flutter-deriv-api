#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::System::Password;
use BOM::Platform::Client;
use Digest::SHA;

my %credentials = (
    environment => 'e',
    scopes      => ['price'],
);

my $CR2002   = BOM::Platform::Client->new({loginid => 'CR2002'});
my $CR3003   = BOM::Platform::Client->new({loginid => 'CR3003'});
my $VRTC1001 = BOM::Platform::Client->new({loginid => 'VRTC1001'});

my $status;

subtest 'Valid Login' => sub {
    ok $CR2002->login(%credentials)->{success},   'Real Account can login';
    ok $VRTC1001->login(%credentials)->{success}, 'Virtual Account can login';
};

subtest 'Disable Virtual logins' => sub {
    BOM::Platform::Runtime->instance->app_config->system->suspend->logins(['VRTC']);

    ok $CR2002->login(%credentials)->{success};

    $status = $VRTC1001->login(%credentials);
    ok !$status->{success}, 'VRTC only suspended, virtual account cannot login';
    ok $status->{error} =~ /Login to this account has been temporarily disabled/;

    BOM::Platform::Runtime->instance->app_config->system->suspend->logins([]);
};

$CR2002->set_status('disabled');
$CR2002->save;

subtest 'Disabled Login' => sub {
    $status = $CR2002->login(%credentials);
    ok !$status->{success}, 'Account disabled, cannot login';
    is $status->{error}, 'This account is unavailable. For any questions please contact Customer Support.';
};


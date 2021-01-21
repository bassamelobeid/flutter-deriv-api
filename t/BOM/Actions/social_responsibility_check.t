use strict;
use warnings;

use utf8;

use Test::More;
use Test::MockModule;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test::Email;

use BOM::User::Client;
use BOM::User::Password;

use BOM::Config::Redis;

use BOM::Event::Actions::Client;

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');

my $user = BOM::User->create(
    email          => $email,
    password       => $hash_pwd,
    email_verified => 1,
);

my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MLT',
    email          => $email,
    residence      => 'hr',
    binary_user_id => $user->id
});

my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MX',
    email          => $email,
    residence      => 'hr',
    binary_user_id => $user->id
});

$user->add_client($client_mx);
$user->add_client($client_mlt);

#mock BOM::User::Client object
my $mock_client = Test::MockModule->new('BOM::User::Client');
my $fa_net_income;
$mock_client->mock(
    get_financial_assessment => sub {
        return $fa_net_income;
    });

my $redis = BOM::Config::Redis::redis_events();
my ($msg, $reg);
#the social responsibility values can be found here:#
# /home/git/regentmarkets/bom-config/share/social_responsibility_thresholds.yml #

subtest 'Generic tests' => sub {

    throws_ok { BOM::Event::Actions::Client::social_responsibility_check({loginid => 'CR5'}) } qr/Invalid/, 'correct exception wrong loginid';

    throws_ok { BOM::Event::Actions::Client::social_responsibility_check() } qr/Missing/, 'correct exception missing loginid';

};

subtest "Increment change in client's values" => sub {

    mailbox_clear();
    $fa_net_income = '$50,001 - $100,000';

    #set redis keys
    my $redis_value = 500;

    for (1 .. 4) {
        $redis->set($client_mx->loginid . ':sr_check:losses',        $redis_value);
        $redis->set($client_mx->loginid . ':sr_check:net_deposits',  $redis_value);
        $redis->set($client_mlt->loginid . ':sr_check:losses',       $redis_value);
        $redis->set($client_mlt->loginid . ':sr_check:net_deposits', $redis_value);

        BOM::Event::Actions::Client::social_responsibility_check($client_mx);
        BOM::Event::Actions::Client::social_responsibility_check($client_mlt);

        if ($redis_value >= 1500) {

            is $redis->get($client_mx->loginid . ':sr_check:losses'), undef, 'redis threshold value \'losses\' is correctly removed for MX client';
            is $redis->get($client_mx->loginid . ':sr_check:net_deposits'), undef,
                'redis threshold value \'net_deposits\' is correctly removed for MX client';
            is $redis->get($client_mlt->loginid . ':sr_check:losses'), undef, 'redis threshold value \'losses\' is correctly removed for MX client';
            is $redis->get($client_mlt->loginid . ':sr_check:net_deposits'), undef,
                'redis threshold value \'net_deposits\' is correctly removed for MX client';

            #test email was sent succefully
            $msg = mailbox_search(subject => qr/Social Responsibility Check required/);

            #need to escape '$' sign else regex like() is not working as it should
            $reg = $fa_net_income;
            $reg =~ s/\$/\\\$/g;

            like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' to email body");

        } else {

            is $redis->get($client_mx->loginid . ':sr_check:losses'), $redis_value, 'redis threshold value \'losses\' is NOT removed for MX client';
            is $redis->get($client_mx->loginid . ':sr_check:net_deposits'), $redis_value,
                'redis threshold value \'net_deposits\' is NOT removed for MX client';
            is $redis->get($client_mlt->loginid . ':sr_check:losses'), $redis_value, 'redis threshold value \'losses\' is NOT removed for MX client';
            is $redis->get($client_mlt->loginid . ':sr_check:net_deposits'), $redis_value,
                'redis threshold value \'net_deposits\' is NOT removed for MX client';
        }

        $redis_value += 500;
    }

    delete_all_keys($client_mlt->loginid);
    delete_all_keys($client_mx->loginid);
    $client_mx->status->clear_unwelcome;

};

subtest 'FA missing' => sub {

    #set FA value
    $fa_net_income = undef;

    #set redis keys
    $redis->set($client_mx->loginid . ':sr_check:losses',       '750');
    $redis->set($client_mx->loginid . ':sr_check:net_deposits', '750');

    mailbox_clear();
    BOM::Event::Actions::Client::social_responsibility_check($client_mx);

    #check keys removed correctly
    is $redis->get($client_mx->loginid . ':sr_check:losses'),       undef, 'redis threshold value \'losses\' removed correctly for MX client';
    is $redis->get($client_mx->loginid . ':sr_check:net_deposits'), undef, 'redis threshold value \'net_deposits\' removed correctly for MX client';

    #check risk status
    is $redis->get($client_mx->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MX client';

    #check unwelcome status
    ok $client_mx->status->unwelcome, "MX client's status is set to unwelcome";

    #test email was sent succefully
    $msg = mailbox_search(subject => qr/Social Responsibility Check required/);
    like($msg->{body}, qr/No FA filled/, 'Correct reason \'No FA filled\' to email body');

    #client fills in the FA but st_risk status remain High
    mailbox_clear();
    $fa_net_income = '$50,001 - $100,000';
    $client_mx->status->clear_unwelcome;

    #client breaches thresholds again
    $redis->set($client_mx->loginid . ':sr_check:losses',       '1500');
    $redis->set($client_mx->loginid . ':sr_check:net_deposits', '1500');

    #sr check
    BOM::Event::Actions::Client::social_responsibility_check($client_mx);

    #check unwelcome status NOT set
    ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome after FA is filled";

    #test email was sent succefully
    $msg = mailbox_search(subject => qr/Social Responsibility Check required/);

    #need to escape '$' sign else regex like() is not working as it should
    $reg = $fa_net_income;
    $reg =~ s/\$/\\\$/g;

    like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' to email body");

    delete_all_keys($client_mx);
    $client_mx->status->clear_unwelcome;

};

subtest 'FA exists' => sub {

    subtest 'FA lower than $25k' => sub {
        #set redis return value
        $redis->set($client_mx->loginid . ':sr_check:losses',        '750');
        $redis->set($client_mx->loginid . ':sr_check:net_deposits',  '750');
        $redis->set($client_mlt->loginid . ':sr_check:losses',       '750');
        $redis->set($client_mlt->loginid . ':sr_check:net_deposits', '750');
        #set FA value
        $fa_net_income = 'Less than $25,000';

        #check for MX client
        mailbox_clear();
        BOM::Event::Actions::Client::social_responsibility_check($client_mx);
        ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome";
        #test email was sent succefully
        #need to escape '$' sign else regex like() is not working as it should
        $reg = $fa_net_income;
        $reg =~ s/\$/\\\$/g;
        $msg = mailbox_search(subject => qr/Social Responsibility Check required/);
        like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' appended to email body for MX client");
        #check risk status
        is $redis->get($client_mx->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MX client';

        #check for MLT client
        mailbox_clear();
        BOM::Event::Actions::Client::social_responsibility_check($client_mlt);
        ok !$client_mlt->status->unwelcome, "MLT client's status is NOT set to unwelcome";
        #test email was sent succefully
        $msg = mailbox_search(subject => qr/Social Responsibility Check required/);
        #need to escape '$' sign else regex like() is not working as it should
        $reg = $fa_net_income;
        $reg =~ s/\$/\\\$/g;
        like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' appended to email body for MLT client");
        #check risk status
        is $redis->get($client_mlt->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MLT client';

        delete_all_keys($client_mlt);
        delete_all_keys($client_mx);

    };

    subtest 'FA higher than $25k' => sub {

        #set FA value
        foreach ('$25,000 - $50,000', '$50,001 - $100,000', '$100,001 - $500,000', 'Over $500,000') {

            $fa_net_income = $_;

            #set redis return value
            $redis->set($client_mx->loginid . ':sr_check:losses',        '1500');
            $redis->set($client_mx->loginid . ':sr_check:net_deposits',  '1500');
            $redis->set($client_mlt->loginid . ':sr_check:losses',       '1500');
            $redis->set($client_mlt->loginid . ':sr_check:net_deposits', '1500');

            #check for MX client
            mailbox_clear();
            BOM::Event::Actions::Client::social_responsibility_check($client_mx);
            ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome for FA: $fa_net_income";
            #test email was sent succefully
            #need to escape '$' sign else regex like() is not working as it should
            $reg = $fa_net_income;
            $reg =~ s/\$/\\\$/g;
            $msg = mailbox_search(subject => qr/Social Responsibility Check required/);
            like($msg->{body}, qr/$reg/, "Correct reason $fa_net_income appended to email body for MX client");

            #check for MLT client
            mailbox_clear();
            BOM::Event::Actions::Client::social_responsibility_check($client_mlt);
            ok !$client_mlt->status->unwelcome, "MLT client's status is NOT set to unwelcome for FA: $fa_net_income";
            #test email was sent succefully
            #need to escape '$' sign else regex like() is not working as it should
            $reg = $fa_net_income;
            $reg =~ s/\$/\\\$/g;
            $msg = mailbox_search(subject => qr/Social Responsibility Check required/);
            like($msg->{body}, qr/$reg/, "Correct reason $fa_net_income appended to email body for MLT client");

            delete_all_keys($client_mlt->loginid);
            delete_all_keys($client_mx->loginid);
        }
    };

};

sub delete_all_keys {

    my $loginid = shift;

    #delete all keys
    foreach my $k ($redis->keys("$loginid*sr*")->@*) {
        $redis->del($k);
    }
    my @keys = $redis->keys("$loginid*sr*")->@*;
    is scalar(@keys), '0', "All keys deleted correctly for " . $loginid;
}

done_testing();

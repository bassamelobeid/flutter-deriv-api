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

    throws_ok { BOM::Event::Actions::Client::social_responsibility_check({loginid => 'CR5', attribute => 'test'}) } qr/Invalid/,
        'correct exception wrong loginid';

    throws_ok { BOM::Event::Actions::Client::social_responsibility_check() } qr/Missing/, 'correct exception missing loginid';

};

my @attributes = qw(losses net_deposits);

subtest "Increment change in client's values" => sub {

    mailbox_clear();
    $fa_net_income = '$50,001 - $100,000';

    foreach my $attribute (@attributes) {

        #set redis keys
        my $redis_value = 500;

        for (1 .. 4) {
            $redis->set($client_mx->loginid . ":sr_check:$attribute",  $redis_value);
            $redis->set($client_mlt->loginid . ":sr_check:$attribute", $redis_value);

            BOM::Event::Actions::Client::social_responsibility_check({
                loginid   => $client_mlt->loginid,
                attribute => $attribute
            });
            BOM::Event::Actions::Client::social_responsibility_check({
                loginid   => $client_mx->loginid,
                attribute => $attribute
            });

            if ($redis_value >= 1500) {

                is $redis->get($client_mx->loginid . ":sr_check:$attribute"), undef,
                    "redis threshold value '$attribute' is correctly removed for MX client";
                is $redis->get($client_mlt->loginid . ":sr_check:$attribute"), undef,
                    "redis threshold value '$attribute' is correctly removed for MLT client";

                is $redis->get($client_mx->loginid . ":sr_check:$attribute:email"), 1, "MX Redis key for email sent was set successfully";
                is $redis->ttl($client_mx->loginid . ":sr_check:$attribute:email"), $redis->ttl($client_mx->loginid . ':sr_risk_status'),
                    "MX Redis key for email sent has correct TTL";

                is $redis->get($client_mlt->loginid . ":sr_check:$attribute:email"), 1, "MLT Redis key for email sent was set successfully";
                is $redis->ttl($client_mlt->loginid . ":sr_check:$attribute:email"), $redis->ttl($client_mlt->loginid . ':sr_risk_status'),
                    "MLT Redis key for email sent has correct TTL";
                #test email was sent succefully
                $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);

                #need to escape '$' sign else regex like() is not working as it should
                $reg = $fa_net_income;
                $reg =~ s/\$/\\\$/g;

                like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' to email body");

            } else {

                is $redis->get($client_mx->loginid . ":sr_check:$attribute"), $redis_value,
                    "redis threshold value '$attribute' is NOT removed for MX client";
                is $redis->get($client_mlt->loginid . ":sr_check:$attribute"), $redis_value,
                    "redis threshold value '$attribute' is NOT removed for MLT client";

                # Check that the redis keyd for email sent are not set
                is $redis->get($client_mx->loginid . ":sr_check:$attribute:email"), undef, "MX Redis key for email sent was NOT set";

                is $redis->get($client_mlt->loginid . ":sr_check:$attribute:email"), undef, "MLT Redis key for email sent was NOT set";
            }

            $redis_value += 500;
        }
    }

    delete_all_keys($client_mlt->loginid);
    delete_all_keys($client_mx->loginid);
    $client_mx->status->clear_unwelcome;

};

subtest 'FA missing' => sub {

    mailbox_clear();
    foreach my $attribute (@attributes) {
        #set FA value
        $fa_net_income = undef;

        #set redis keys
        $redis->set($client_mx->loginid . ':sr_check:losses',       '750');
        $redis->set($client_mx->loginid . ':sr_check:net_deposits', '750');

        BOM::Event::Actions::Client::social_responsibility_check({
            loginid   => $client_mx->loginid,
            attribute => $attribute
        });

        #check keys removed correctly
        is $redis->get($client_mx->loginid . ":sr_check:$attribute"), undef, "redis threshold value '$attribute' removed correctly for MX client";

        #check risk status
        is $redis->get($client_mx->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MX client';

        #check unwelcome status
        ok $client_mx->status->unwelcome, "MX client's status is set to unwelcome";

        #test email was sent succefully
        $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);
        like($msg->{body}, qr/No FA filled/, 'Correct reason \'No FA filled\' to email body');

        #client fills in the FA but sr_risk status remain High
        mailbox_clear();
        $fa_net_income = '$50,001 - $100,000';
        $client_mx->status->clear_unwelcome;

        #client breaches thresholds again
        $redis->set($client_mx->loginid . ":sr_check:$attribute", '1500');

        #sr check
        BOM::Event::Actions::Client::social_responsibility_check({
            loginid   => $client_mx->loginid,
            attribute => $attribute
        });

        #check unwelcome status NOT set
        ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome after FA is filled";

        #test email was sent succefully
        $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);

        #need to escape '$' sign else regex like() is not working as it should
        $reg = $fa_net_income;
        $reg =~ s/\$/\\\$/g;

        like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' to email body");

        delete_all_keys($client_mx->loginid);
        $client_mx->status->clear_unwelcome;
    }

    delete_all_keys($client_mx->loginid);
    $client_mx->status->clear_unwelcome;

};

subtest 'FA exists' => sub {

    subtest 'FA lower than $25k' => sub {
        foreach my $attribute (@attributes) {
            #set redis return value
            $redis->set($client_mx->loginid . ":sr_check:$attribute",  '750');
            $redis->set($client_mlt->loginid . ":sr_check:$attribute", '750');
            #set FA value
            $fa_net_income = 'Less than $25,000';

            #check for MX client
            mailbox_clear();
            BOM::Event::Actions::Client::social_responsibility_check({
                loginid   => $client_mx->loginid,
                attribute => $attribute
            });
            ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome";
            #test email was sent succefully
            #need to escape '$' sign else regex like() is not working as it should
            $reg = $fa_net_income;
            $reg =~ s/\$/\\\$/g;
            $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);
            like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' appended to email body for MX client");
            #check risk status
            is $redis->get($client_mx->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MX client';

            #check for MLT client
            mailbox_clear();
            BOM::Event::Actions::Client::social_responsibility_check({
                loginid   => $client_mlt->loginid,
                attribute => $attribute
            });
            ok !$client_mlt->status->unwelcome, "MLT client's status is NOT set to unwelcome";
            #test email was sent succefully
            $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);
            #need to escape '$' sign else regex like() is not working as it should
            $reg = $fa_net_income;
            $reg =~ s/\$/\\\$/g;
            like($msg->{body}, qr/$reg/, "Correct reason '$fa_net_income' appended to email body for MLT client");
            #check risk status
            is $redis->get($client_mlt->loginid . ':sr_risk_status'), 'high', 'High risk status set correctly for MLT client';

            delete_all_keys($client_mlt->loginid);
            delete_all_keys($client_mx->loginid);
        }
    };

    subtest 'FA higher than $25k' => sub {

        #set FA value
        foreach my $attribute (@attributes) {

            foreach ('$25,000 - $50,000', '$50,001 - $100,000', '$100,001 - $500,000', 'Over $500,000') {

                $fa_net_income = $_;

                #set redis return value
                $redis->set($client_mx->loginid . ":sr_check:$attribute",  '1500');
                $redis->set($client_mlt->loginid . ":sr_check:$attribute", '1500');

                #check for MX client
                mailbox_clear();
                BOM::Event::Actions::Client::social_responsibility_check({
                    loginid   => $client_mx->loginid,
                    attribute => $attribute
                });
                ok !$client_mx->status->unwelcome, "MX client's status is NOT set to unwelcome for FA: $fa_net_income";
                #test email was sent succefully
                #need to escape '$' sign else regex like() is not working as it should
                $reg = $fa_net_income;
                $reg =~ s/\$/\\\$/g;
                $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);
                like($msg->{body}, qr/$reg/, "Correct reason $fa_net_income appended to email body for MX client");

                #check for MLT client
                mailbox_clear();
                BOM::Event::Actions::Client::social_responsibility_check({
                    loginid   => $client_mlt->loginid,
                    attribute => $attribute
                });
                ok !$client_mlt->status->unwelcome, "MLT client's status is NOT set to unwelcome for FA: $fa_net_income";
                #test email was sent succefully
                #need to escape '$' sign else regex like() is not working as it should
                $reg = $fa_net_income;
                $reg =~ s/\$/\\\$/g;
                $msg = mailbox_search(subject => qr/Social Responsibility Check required \($attribute\)/);
                like($msg->{body}, qr/$reg/, "Correct reason $fa_net_income appended to email body for MLT client");

                delete_all_keys($client_mlt->loginid);
                delete_all_keys($client_mx->loginid);
            }
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

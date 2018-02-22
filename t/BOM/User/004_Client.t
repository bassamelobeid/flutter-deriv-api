use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

my $login_id = 'CR0011';
my $client;

is_deeply [sort { $a cmp $b } keys %{BOM::User::Client::client_status_types()}], [
    sort { $a cmp $b }
        qw/age_verification cashier_locked disabled unwelcome withdrawal_locked ukgc_funds_protection tnc_approval crs_tin_information financial_risk_approval ukrts_max_turnover_limit_not_set jp_knowledge_test_pending jp_knowledge_test_fail jp_activation_pending jp_transaction_detail migrated_single_email duplicate_account document_under_review document_needs_action ico_only
        professional_requested professional/
    ],
    "correct number of client status";

Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

my $broker = $client->broker;

my $undef;
my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';

# first time, client cashier is not lock
is($client->get_status('unwelcome'), $undef, "client is not in unwelcome login");

# lock client cashier
Test::Exception::lives_ok { $client->set_status('unwelcome', $clerk, $reason) } "set client unwelcome login";

# save changes to CR.lockcashierlogins
Test::Exception::lives_ok { $client->save() } "can save to unwelcome login file";

# recreate client
Test::Exception::lives_ok { $client = BOM::User::Client::get_instance({loginid => $login_id}) } "Can create client $login_id";

# re-read from CR.lockcashierlogins, whether client is disabled cashier
my $unwelcome = $client->get_status('unwelcome');
is($unwelcome->reason,     $reason, "client is in unwelcome login, reason OK");
is($unwelcome->staff_name, $clerk,  "client is in unwelcome login, clerk OK");

# enable client cashier back
Test::Exception::lives_ok { $client->clr_status('unwelcome') } "delete client from unwelcome login";

# save changes to CR.lockcashierlogins
Test::Exception::lives_ok { $client->save } "can save to unwelcome login file";

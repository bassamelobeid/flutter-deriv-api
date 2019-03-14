#!/usr/bin/env perl
use strict;
use warnings;

use BOM::User::Client;
use JSON::MaybeUTF8 qw(:v1);
use Locale::Country;
use Text::CSV;
use Try::Tiny;
use LandingCompany::Registry;
use Getopt::Long;
use Path::Tiny;
use Date::Utility;
use Log::Any qw($log);
use Log::Any::Adapter 'Stderr';
use constant MAX_FAIL_COUNT => 100;

my $csv = Text::CSV->new({eol => "\n"})
    or die "Cannot use CSV: " . Text::CSV->error_diag();

my $out_path;

# It is important to have VRTC as the last broker as we don't want to include virtual accounts whose users have real accounts.
my @real_brokers = ("CR", "MF", "MLT", "MX", "VRTC");

my @new_columns = (
    "id",           "email",        "created_at",   "company", "language", "first_name", "last_name", "affiliate_token",
    "unsubscribed", "account_type", "country_code", "country", "is_region_eu"
);

$csv->column_names(@new_columns);

GetOptions('o|outpath=s' => \$out_path);

$out_path //= 'out.csv';

my $fho = path($out_path)->openw_utf8;

$csv->print($fho, \@new_columns);

my %failed_ids;
my $ok_count   = 0;
my $fail_count = 0;
my %processed_user_ids;

for my $broker (@real_brokers) {
    my $users = users_for_broker($broker);
    for my $userid (@$users) {
        next if $processed_user_ids{$userid};
        $processed_user_ids{$userid} = 1;

        my $user = BOM::User->new(id => $userid);

        for my $loginid ($user->bom_loginids) {
            try {
                $csv->print_hr($fho, generate_data($loginid));
                $ok_count++;
            }
            catch {
                $failed_ids{$loginid} = $_;
                $fail_count++;
                if ($fail_count > MAX_FAIL_COUNT) {
                    $log->error("Max Fail Count " . MAX_FAIL_COUNT . " exceeded. Process stopped.");
                    $log->error($_ . " : " . $failed_ids{$_}) for keys %failed_ids;
                    die;
                }
            };
        }
    }
}

$log->notice("-----------\n");
$log->notice("Success Count : $ok_count\n");
$log->notice("Fail Count : " . scalar(keys %failed_ids) . "\n");
$log->notice("Failed IDS : \n") if %failed_ids;
$log->notice($_ . " : " . $failed_ids{$_}) for keys %failed_ids;
$log->notice("-----------\n");

close $fho;

#--------------------------------------------------------------------------------#

sub generate_data {
    my $loginid = shift;
    my %data;

    my $client = BOM::User::Client->new({loginid => $loginid});
    my $user = $client->user;

    $data{id}              = $loginid;
    $data{email}           = $client->email;
    $data{created_at}      = Date::Utility->new($client->date_joined)->epoch;
    $data{company}         = $client->landing_company->short;
    $data{language}        = "EN";
    $data{first_name}      = $client->first_name;
    $data{last_name}       = $client->last_name;
    $data{affiliate_token} = $client->myaffiliates_token // '';
    $data{unsubscribed}    = $user->email_consent ? "false" : "true";
    $data{account_type}    = $client->is_virtual ? "virtual" : "real";
    $data{country_code}    = $client->residence // '';
    $data{country} =
        $client->residence
        ? Locale::Country::code2country($client->residence)
        : '';
    $data{is_region_eu} = $client->is_region_eu;

    return \%data;
}

sub users_for_broker {
    my $broker = shift;
    my $dbic   = get_db_for_broker($broker)->dbic;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectcol_arrayref("select * from betonmarkets.users_with_transactions_since(?)",
                {}, Date::Utility->new()->_minus_months(6)->datetime_yyyymmdd_hhmmss);
        });

    return $result;
}

sub get_db_for_broker {
    return BOM::Database::ClientDB->new({
            broker_code => shift,
            operation   => 'replica',
        })->db;
}

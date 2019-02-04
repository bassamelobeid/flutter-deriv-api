
=head1 NAME

cron_mt5_authentication_check.pl

=head1 DESCRIPTION

This is a CRON script to send a reminder to CR clients, who are not authenticated, and
have a financial MT5 account. The email will be sent, as long as it is five days after
the creation of the MT5 account. An email will be sent to CS everyday, listing the mt5
accounts to disable

=cut

package main;
use strict;
use warnings;

use Brands;
use LandingCompany::Registry;

use BOM::User;
use BOM::MT5::User::Async;
use BOM::Config::RedisReplicated;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(localize);
use BOM::Backoffice::Request;

use Date::Utility;
use List::MoreUtils qw/first_index/;
use JSON::MaybeUTF8 qw/decode_json_utf8 encode_json_utf8/;
use Path::Tiny qw(path);
use Text::CSV;

use constant REDIS_MASTERKEY               => 'MT5_REMINDER_AUTHENTICATION_CHECK';
use constant MT5_EMAIL_AUTHENTICATION_DAYS => 5;
use constant MT5_ACCOUNT_DISABLE_DAYS      => 10;

sub send_email_to_client_fifth_day {

    my ($days_between_account_creation, $client, $data, $brands, $redis) = @_;

    # Edge case: if the email is sent but the number of days is more than five, we need to handle this
    # Example: if four days are remaining, email content should mention that client has four days remaining
    my $days_left_before_disable = MT5_ACCOUNT_DISABLE_DAYS - $days_between_account_creation;
    my $last_date                = Date::Utility->new()->plus_time_interval($days_left_before_disable . 'd')->date_ddmmmyyyy;

    $last_date =~ s/-/ /g;

    my $mt5_followup_email;

    BOM::Backoffice::Request::template()->process(
        "email/mt5_authentication_reminder_email.html.tt",
        {
            full_name => $client->full_name,
            last_date => $last_date
        },
        \$mt5_followup_email
    );

    send_email({
        from                  => $brands->emails('support'),
        to                    => $client->email,
        subject               => localize('IMPORTANT: Authenticate your MT5 real money account to continue trading'),
        message               => [$mt5_followup_email],
        email_content_is_html => 1,
        use_email_template    => 1,
        skip_text2html        => 1
    });

    # Mark the email as sent
    $data->{has_email_sent} = 1;
    $redis->hset(REDIS_MASTERKEY, $client->binary_user_id, encode_json_utf8($data));

    return undef;
}

sub create_csv_rows {

    my ($brands, $user, $client, $redis) = @_;

    my $loginid_info = $client->loginid . ' (' . $client->currency . ')';

    # Send client the email that their account will be disabled
    my $mt5_disable_email;

    BOM::Backoffice::Request::template()->process("email/disable_mt5_accounts_email.html.tt", {full_name => $client->full_name}, \$mt5_disable_email);

    send_email({
        from                  => $brands->emails('support'),
        to                    => $client->email,
        subject               => localize('IMPORTANT: Your MT5 real money account has been disabled'),
        message               => [$mt5_disable_email],
        email_content_is_html => 1,
        use_email_template    => 1,
        skip_text2html        => 1
    });

    my @new_csv_rows;
    my $csv_row = [];

    my @mt5_loginids = sort grep { /^MT\d+$/ } $user->loginids;

    foreach my $mt5_loginid (@mt5_loginids) {

        $mt5_loginid =~ s/\D//g;
        my $result = BOM::MT5::User::Async::get_user($mt5_loginid)->get;

        next unless $result->{group} =~ /^real\\(vanuatu|labuan)/;

        my $open_positions = BOM::MT5::User::Async::get_open_positions_count($mt5_loginid)->get;

        $csv_row = [$loginid_info, $mt5_loginid, $result->{group}, $result->{balance}, $open_positions->{total}];
        push @new_csv_rows, $csv_row;
    }

    $redis->hdel(REDIS_MASTERKEY, $user->{id});

    return @new_csv_rows;
}

my @csv_rows;

my $redis   = BOM::Config::RedisReplicated::redis_write();
my @all_ids = @{$redis->hkeys(REDIS_MASTERKEY)};

my $brands = Brands->new(name => BOM::Backoffice::Request::request()->brand);
my $present_day = Date::Utility->new();

foreach my $id (@all_ids) {
    my $user = BOM::User->new(id => $id);

    # real\\vanuatu or labuan is only for costarica clients
    my @clients = $user->clients_for_landing_company('costarica');

    # Priority is getting fiat currency, as it is easier for payments for currency conversion
    my $fiat_index = first_index { LandingCompany::Registry::get_currency_type($_->currency) eq 'fiat' } @clients;

    my $client;
    $client = $fiat_index == -1 ? $clients[0] : $clients[$fiat_index];

    # Remove from redis if client is authenticated
    if ($client->fully_authenticated) {
        $redis->hdel(REDIS_MASTERKEY, $id);
        next;
    }

    my $data = decode_json_utf8($redis->hget(REDIS_MASTERKEY, $id));

    my $mt5_creation_day              = Date::Utility->new($data->{creation_epoch});
    my $days_between_account_creation = $present_day->days_between($mt5_creation_day);

    # Move to next loop if the days passed is before the authentication follow up day
    next if $days_between_account_creation < MT5_EMAIL_AUTHENTICATION_DAYS;

    # Send email to client five days after account creation
    send_email_to_client_fifth_day($days_between_account_creation, $client, $data, $brands, $redis) unless $data->{has_email_sent};

    # Save the client details in CSV if 10 days have passed after account creation
    if ($days_between_account_creation == MT5_ACCOUNT_DISABLE_DAYS) {
        my @new_csv_rows = create_csv_rows($brands, $user, $client, $redis);
        push @csv_rows, @new_csv_rows;
    }
}

$present_day = $present_day->date_yyyymmdd;

my $csv = Text::CSV->new({
    eol        => "\n",
    quote_char => undef
});

# CSV creation starts here
my $filename = 'mt5_disable_list_' . $present_day . '.csv';

{
    my $file = path($filename)->openw_utf8;
    my @headers = ('Loginid (Currency)', 'MT5 ID', 'MT5 Group', 'MT5 Balance', 'Open Positions');

    $csv->print($file, \@headers);
    $csv->print($file, $_) for @csv_rows;
}
# CSV creation ends here

send_email({
    'from'       => $brands->emails('system'),
    'to'         => $brands->emails('support'),
    'subject'    => 'List of MT5 accounts to disable -  ' . $present_day,
    'attachment' => $filename,
});

path($filename)->remove;

1;

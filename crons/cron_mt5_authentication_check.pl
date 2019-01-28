
=head1 NAME

cron_mt5_authentication_check.pl

=head1 DESCRIPTION

This is a CRON script to send a reminder to CR clients, who are not authenticated, and
have a financial MT5 account. The email will be sent, as long as it is five days after
the creation of the MT5 account. Five days after the email has been sent, CS will disable their MT5 account(s) 
and close any open positions that they may have on the MT5 platform 

=cut

package main;
use strict;
use warnings;

use Brands;

use BOM::User;
use BOM::Config::RedisReplicated;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(localize);
use BOM::Backoffice::Request;

use Date::Utility;
use JSON::MaybeUTF8 qw/decode_json_utf8 encode_json_utf8/;

my $brands = Brands->new();

my $present_day = Date::Utility->new();

# Fetch the list of ids
my $redis = BOM::Config::RedisReplicated::redis_write();

use constant REDIS_MASTERKEY               => 'MT5_REMINDER_AUTHENTICATION_CHECK';
use constant MT5_EMAIL_AUTHENTICATION_DAYS => 5;
use constant MT5_ACCOUNT_DISABLE_DAYS      => 10;

my @all_ids = @{$redis->hkeys(REDIS_MASTERKEY)};

foreach my $id (@all_ids) {
    my $user = BOM::User->new(id => $id);

    # real\\vanuatu or labuan is only for costarica clients
    my @clients = $user->clients_for_landing_company('costarica');
    my $client  = $clients[0];

    # Check if client has been authenticated or not
    # Remove from redis if so
    if ($client->fully_authenticated) {
        $redis->hdel(REDIS_MASTERKEY, $id);
        next;
    }

    my $data = decode_json_utf8($redis->hget(REDIS_MASTERKEY, $id));
    my $mt5_creation_day = Date::Utility->new($data->{creation_epoch});

    # Send email and remove from redis
    # NOTE: As per CS, this email should be sent five days after a financial account is created
    # and if the client is still not authenticated.
    my $days_between_account_creation = $present_day->days_between($mt5_creation_day);

    # Do not send email more than once
    # Delete it on the 10th day, as CS will be disabling the MT5 accounts
    if ($data->{has_email_sent}) {
        $redis->hdel(REDIS_MASTERKEY, $id) if ($days_between_account_creation == MT5_ACCOUNT_DISABLE_DAYS);
        next;
    }

    if (($days_between_account_creation >= MT5_EMAIL_AUTHENTICATION_DAYS) && ($days_between_account_creation < MT5_ACCOUNT_DISABLE_DAYS)) {

        my $mt5_5th_day_email;

        # Edge case: if the email is sent but the number of days is more than five, we need to handle this
        # Example: if four days are remaining, email content should mention that client has four days remaining
        my $days_left_before_disable = MT5_ACCOUNT_DISABLE_DAYS - $days_between_account_creation;
        my $last_date                = Date::Utility->new()->plus_time_interval($days_left_before_disable . 'd')->date_ddmmmyyyy;

        $last_date =~ s/-/ /g;

        BOM::Backoffice::Request::template()->process(
            "email/mt5_authentication_reminder_email.html.tt",
            {
                full_name => $client->full_name,
                last_date => $last_date
            },
            \$mt5_5th_day_email
        );

        send_email({
            from                  => $brands->emails('support'),
            to                    => $client->email,
            subject               => localize('IMPORTANT: Authenticate your MT5 real money account to continue trading'),
            message               => [$mt5_5th_day_email],
            email_content_is_html => 1,
            use_email_template    => 1
        });

        # Mark the email as sent
        $data->{has_email_sent} = 1;
        $redis->hset(REDIS_MASTERKEY, $id, encode_json_utf8($data));
    }

}

1;

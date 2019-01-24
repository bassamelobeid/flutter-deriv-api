package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Try::Tiny;

use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

use BOM::Platform::Event::Emitter;
use BOM::User::Client;
use BOM::MT5::User::Async;

use Brands;
use Cache::RedisDB;
use Email::Stuffer;
use RedisDB;
use YAML::XS;

use constant DAYS_TO_EXPIRE => 14;
use constant SECONDS_IN_DAY => 86400;

=head2 sync_info

Sync user information to MT5

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process

=back

=cut

sub sync_info {
    my $data = shift;
    return undef unless $data->{loginid};

    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return 1 if $client->is_virtual;

    my $user = $client->user;
    my @update_operations;

    # TODO: use $user->mt5_logins once it's fixed and it doesn't hit MT5
    for my $mt_login (sort grep { /^MT\d+$/ } $user->loginids) {
        my $operation = BOM::MT5::User::Async::update_user({
                login => do { $mt_login =~ /(\d+)/; $1 },
                %{$client->get_mt5_details()}});

        push @update_operations, $operation;
    }

    my $result = Future->needs_all(@update_operations)->get();

    if ($result->{error}) {
        $log->warn("Failed to sync client $data->{loginid} information to MT5: $result->{error}");
        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $data->{loginid}});
        return 0;
    }

    return 1;
}

sub redis_record_mt5_transfer {
    my $input_data = shift;
    my $redis      = BOM::Config::RedisReplicated::redis_write;
    my $loginid    = $input_data->{loginid};
    my $mt5_id     = $input_data->{mt5_id};
    my $redis_key  = $mt5_id . "_" . $input_data->{action};
    my $mt5_group  = Cache::RedisDB->get('MT5_USER_GROUP', $mt5_id);
    $mt5_group //= 'unknown';
    my $data;

    return undef unless ($mt5_group =~ /real\\vanuatu_standard/);

    # check if the mt5 id exists in redis
    if ($redis->get($redis_key)) {
        $redis->incrbyfloat($redis_key, $input_data->{amount_in_USD});
    } else {
        $redis->set($redis_key, $input_data->{amount_in_USD});
    }

    # set duration to expire in 14 days
    $redis->expire($redis_key, SECONDS_IN_DAY * DAYS_TO_EXPIRE);

    my $total_amount = $redis->get($redis_key);

    if ($total_amount >= 8000) {
        notifiy_compliance_mt5_over8K({
                loginid      => $loginid,
                mt5_id       => $mt5_id,
                action       => $input_data->{action},
                total_amount => sprintf("%.2f", $total_amount)});

        $redis->del($redis_key);
    }

    return 1;
}

sub notifiy_compliance_mt5_over8K {
    # notify compliance about the situation
    my $data                   = shift;
    my $brands                 = Brands->new();
    my $system_email           = $brands->emails('system');
    my $compliance_alert_email = $brands->emails('compliance_alert');
    my $mt5_group              = Cache::RedisDB->get('MT5_USER_GROUP', $data->{mt5_id});
    $mt5_group //= 'unknown';
    $data->{mt5_group} = $mt5_group;

    my $email_subject = 'VN - International currency transfers reporting obligation';

    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/mt5_8k.html.tt', $data, \my $html);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return {status_code => 0};
    }

    my $email_status = Email::Stuffer->from($system_email)->to($compliance_alert_email)->subject($email_subject)->html_body($html)->send();
    unless ($email_status) {
        $log->warn('failed to send email.');
        return {status_code => 0};
    }

    return 1;
}

1;

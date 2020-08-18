package BOM::Event::Actions::MT5;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);

use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use BOM::MT5::User::Async;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Event::Services::Track;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::Platform::Client::Sanctions;

use Email::Stuffer;
use YAML::XS;
use Date::Utility;
use Text::CSV;
use List::Util qw(any);
use Path::Tiny qw(tempdir);
use JSON::MaybeUTF8 qw/encode_json_utf8/;
use DataDog::DogStatsd::Helper;

use Future;
use IO::Async::Loop;
use Net::Async::Redis;

use List::Util qw(sum0);
use HTML::Entities;
use BOM::User::Utility qw(parse_mt5_group);

use constant DAYS_TO_EXPIRE => 14;
use constant SECONDS_IN_DAY => 86400;

{
    my $redis_mt5user;

    # Provides an instance for communicating with the Onfido web API.
    # Since we're adding this to our event loop, it's a singleton - we
    # don't want to leak memory by creating new ones for every event.
    sub _redis_mt5user_write {
        return $redis_mt5user //= do {
            my $loop = IO::Async::Loop->new;
            $loop->add(my $redis = Net::Async::Redis->new(uri => BOM::Config::Redis::redis_config('mt5_user', 'write')->{uri}));
            $redis;
        }
    }
}

=head2 sync_info

Sync user information to MT5

=over 4

=item * C<data> - data passed in from BOM::Event::Process::process, which is a hashref and have the following keys:

=item * C<loginid> - the login ID for the client to sync data

=item * C<tried_times> - Number of times that this event has been tried

=back

=cut

sub sync_info {
    my $data = shift;
    return undef unless $data->{loginid};
    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return 1 if $client->is_virtual;

    my $user = $client->user;
    my @update_operations;

    # If user is disabled MT5 will re-enable it again
    # we have to access MT5 and get the previous user status
    for my $mt_login (sort $user->get_mt5_loginids) {
        my $operation = BOM::MT5::User::Async::get_user($mt_login)->then(
            sub {
                my $mt_user = shift;
                # BOM::MT5::User::Async doesn't ->fail a future on MT5 errors
                return Future->fail($mt_user->{error}) if $mt_user->{error};
                return BOM::MT5::User::Async::update_user({
                        login  => $mt_login,
                        rights => $mt_user->{rights},
                        %{$client->get_mt5_details()}});
            }
        )->then(
            sub {
                my $result = shift;
                return Future->fail($result->{error}) if $result->{error};
                return Future->done($result);
            });
        push @update_operations, $operation;
    }

    return Future->needs_all(@update_operations)->then_done(1)->else(
        sub {
            my $error       = shift;
            my $tried_times = $data->{tried_times} // 0;
            $tried_times++;
            # if that error cannot recoverable
            if ($error =~ /Not found/i) {
                DataDog::DogStatsd::Helper::stats_inc('event.mt5.sync_info.unrecoverable_error');
            } elsif ($tried_times < 5) {
                BOM::Platform::Event::Emitter::emit(
                    'sync_user_to_MT5',
                    {
                        loginid     => $data->{loginid},
                        tried_times => $tried_times
                    });
            }
            # we tried too many times already
            else {
                DataDog::DogStatsd::Helper::stats_inc('event.mt5.sync_info.retried_error');
            }
            return Future->done(0);
        })->get();
}

sub redis_record_mt5_transfer {
    my $input_data = shift;
    my $redis      = BOM::Config::Redis::redis_mt5_user_write();
    my $loginid    = $input_data->{loginid};
    my $mt5_id     = $input_data->{mt5_id};
    my $redis_key  = 'MT5_TRANSFER_' . (uc $input_data->{action}) . '::' . $mt5_id;

    # check if the mt5 id exists in redis
    if ($redis->get($redis_key)) {
        $redis->incrbyfloat($redis_key, $input_data->{amount_in_USD});
    } else {
        $redis->set($redis_key, $input_data->{amount_in_USD});
        # set duration to expire in 14 days
        $redis->expire($redis_key, SECONDS_IN_DAY * DAYS_TO_EXPIRE);
    }

    my $total_amount = $redis->get($redis_key);

    if ($total_amount >= 8000) {
        notifiy_compliance_mt5_over8K({
                loginid      => $loginid,
                mt5_id       => $mt5_id,
                ttl          => $redis->ttl($redis_key),
                action       => $input_data->{action},
                total_amount => sprintf("%.2f", $total_amount)});

        $redis->del($redis_key);
    }

    return 1;
}

sub notifiy_compliance_mt5_over8K {
    # notify compliance about the situation
    my $data                   = shift;
    my $brand                  = request()->brand();
    my $system_email           = $brand->emails('system');
    my $compliance_alert_email = $brand->emails('compliance_alert');

    my $seconds_passed_since_start = (SECONDS_IN_DAY * DAYS_TO_EXPIRE) - $data->{ttl};
    my $start_time_epoch           = (Date::Utility->new()->epoch()) - $seconds_passed_since_start;
    $data->{start_date} = Date::Utility->new($start_time_epoch)->datetime();
    $data->{end_date}   = Date::Utility->new()->datetime();

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

=head2 new_mt5_signup

This stores the binary_user_id and the timestamp when an unauthenticated CR-client opens a
financial MT5 account. It also sends the user an email to remind them to authenticate, if they
have not

=cut

sub new_mt5_signup {
    my $data   = shift;
    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    return unless $client;

    my $id = $data->{mt5_login_id};

    my $cache_key  = "MT5_USER_GROUP::" . $id;
    my $group      = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'group');
    my $hex_rights = BOM::Config::mt5_user_rights()->{'rights'};

    my %known_rights = map { $_ => hex $hex_rights->{$_} } keys %$hex_rights;

    if ($group->[0]) {
        my $status = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'rights');

        my %rights;

        # This should now have the following keys set:
        # api,enabled,expert,password,reports,trailing
        # Example: status (483 => 1E3)
        $rights{$_} = 1 for grep { $status->[0] & $known_rights{$_} } keys %known_rights;

    } else {
        # ... and if we don't, queue up the request. This may lead to a few duplicates
        # in the queue - that's fine, we check each one to see if it's already
        # been processed.
        BOM::Config::Redis::redis_mt5_user_write()->lpush('MT5_USER_GROUP_PENDING', join(':', $id, time));
    }

    my $group_details   = parse_mt5_group($data->{mt5_group});
    my $company_actions = LandingCompany::Registry->new->get($group_details->{company})->actions // {};
    if ($group_details->{category} ne 'demo' && any { $_ eq 'sanctions' } ($company_actions->{signup} // [])->@*) {
        BOM::Platform::Client::Sanctions->new(
            client                        => $client,
            brand                         => request()->brand,
            recheck_authenticated_clients => 1
        )->check(
            comments     => "Triggered by a new MT5 signup - MT5 loginid: $id and MT5 group: $data->{mt5_group}",
            triggered_by => "$id ($data->{mt5_group}) signup",
        );
    }

    # Sending email to client about mt5 account opening
    send_mt5_account_opening_email({
        mt5_login_id => $id,
        mt5_group    => $data->{mt5_group},
        client       => $client
    });

    # Add email params to track signup event
    $data->{client_first_name} = $client->first_name;
    $data->{type_label}        = ucfirst $group_details->{type_label};    # Frontend-ish label (Synthetic, Financial, Financial STP)
    $data->{mt5_integer_id}    = $id =~ s/${\BOM::User->MT5_REGEX}//r;    # This one is just the numeric ID

    return BOM::Event::Services::Track::new_mt5_signup({
        loginid    => $data->{loginid},
        properties => $data
    });
}

=head2 mt5_password_changed

It is triggered for each B<mt5_password_changed> event emitted.
It can be called with the following parameters:

=over

=item * C<args> - required. Including the login Id of the user with required properties.

=back

=cut

sub mt5_password_changed {
    my ($args) = @_;

    return BOM::Event::Services::Track::mt5_password_changed({
        loginid    => $args->{loginid},
        properties => $args
    });

}

=head2 send_mt5_account_opening_email

Sends an email to client regarding mt5 account opening.
It needs a hashref as param, expected keys:

=over 4

=item * C<mt5_login_id> - mt5 login id
=item * C<mt5_group> - mt5 group
=item * C<client> - the client itself, so we can email him/her and customize email template

=back

=cut

sub send_mt5_account_opening_email {
    my $params       = shift;
    my $brand        = request()->brand;
    my $mt5_login_id = $params->{mt5_login_id};
    my $mt5_group    = $params->{mt5_group};
    my $client       = $params->{client};

    # This is just for Binary customers
    # Deriv emails are handled by Segment
    return unless $brand->send_signin_email_enabled;
    return unless $mt5_login_id;
    return unless $mt5_group;

    my $mt5_details       = parse_mt5_group($mt5_group);
    my $mt5_type_label    = ucfirst $mt5_details->{type_label} =~ s/stp$/STP/r;
    my $mt5_category      = $mt5_details->{category};
    my $mt5_loginid       = $mt5_login_id =~ s/${\BOM::User->MT5_REGEX}//r;
    my $email             = $client->email;
    my $client_first_name = $client->first_name;
    my $lang              = lc(request()->language // 'en');
    my $website_name      = $brand->website_name;

    send_email({
            from          => $brand->emails('no-reply'),
            to            => $email,
            subject       => localize('MT5 [_1] Account Created.', ucfirst $mt5_category),
            template_name => 'mt5_account_opening',
            template_args => {
                mt5_loginid       => $mt5_loginid,
                mt5_category      => $mt5_category,
                mt5_type_label    => $mt5_type_label,
                client_first_name => $client_first_name,
                lang              => $lang,
                website_name      => $website_name
            },
            use_email_template => 1,
        });

    return;
}

1;

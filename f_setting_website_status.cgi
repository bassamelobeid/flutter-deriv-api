#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
BOM::Backoffice::Sysinit::init();

use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);
use Log::Any qw($log);
use BOM::Backoffice::CGI::SettingWebsiteStatus qw/get_redis_keys get_statuses get_messages/;
use BOM::Backoffice::CGI::SettingWebsiteStatus;

my $cgi = CGI->new;
PrintContentType();

my $csrf         = BOM::Backoffice::Form::get_csrf_token();
my $redis        = BOM::Config::Redis->redis_ws_write();
my $is_on_key    = get_redis_keys()->{is_on};
my $state_key    = get_redis_keys()->{state};
my $channel_name = get_redis_keys()->{channel};
my @statuses     = @{get_statuses()};
my %reasons      = %{get_messages()};
my %input        = %{request()->params};
my @flash;

if (request()->http_method eq 'POST') {
    my %input = %{request()->params};
    return_bo_error('Invalid CSRF Token') unless ($input{csrf} // '') eq $csrf;

    my $status = $input{status} // '';
    my $reason = $input{reason} // '';

    return_bo_error('Invalid status') unless grep { $status eq $_ } @statuses;
    return_bo_error('Invalid reason')
        unless grep { $reason eq $_ } (keys %reasons, '');    # Add empty string so the 'None' message can pass

    try {
        $redis->set($is_on_key, 1);
        my $mess_obj = {site_status => $status};
        $mess_obj->{message} = $reason if $reason;
        $mess_obj = encode_json_utf8($mess_obj);
        $redis->set($state_key, $mess_obj);
        $redis->publish($channel_name, $mess_obj);

        push @flash, "Status: $status";
        push @flash, "Message: " . $reasons{$reason} if defined $reasons{$reason};
    } catch ($e) {
        $log->errorf('Cannot set site status: %s', $e);
        return_bo_error('Cannot set site status');
    }
}

my $state = eval { decode_json_utf8($redis->get($state_key) // '{}') };
$state->{site_status} //= 'up';
$state->{message}     //= '';
BrokerPresentation("WEB SITE SETTINGS");

BOM::Backoffice::Request::template()->process(
    'backoffice/setting_website_status.html.tt',
    {
        site_status  => $state->{site_status},
        site_message => $state->{message},
        statuses     => \@statuses,
        reasons      => \%reasons,
        input        => \%input,
        csrf         => $csrf,
        flash        => \@flash
    });

code_exit_BO();

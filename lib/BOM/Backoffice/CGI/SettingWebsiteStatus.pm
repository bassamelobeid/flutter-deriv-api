package BOM::Backoffice::CGI::SettingWebsiteStatus;

use strict;
use warnings;

=head1 NAME

BOM::Backoffice::CGI::SettingWebsiteStatus

=head1 DESCRIPTION

A helper package for f_setting_website_status.cgi

=cut

use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use Digest::SHA qw(sha256_hex);
use Exporter 'import';
our @EXPORT_OK = qw(get_redis_keys return_bo_error get_statuses get_messages);

=head2 Constants

Put all constants used on cgi page here.

=cut

use constant {
    MESSAGES => {
        cashier_issues => 'Cashier issues',
        release_due    => 'Release is in-progress',
        feed_issues    => 'Feed issues',
        mt5_issues     => 'MT5 issues',
        suspended      => 'Trading is suspended',
        unstable       => 'Site is unstable',
    },
    STATUSES        => ['up', 'down'],
    CSRF_TOKEN_SALT => 'r14P0fT904tyuIF343f93P03p3',
    REDIS_KEYS      => {
        channel => "NOTIFY::broadcast::channel",
        state   => "NOTIFY::broadcast::state",
        is_on   => "NOTIFY::broadcast::is_on"
    }};

=head2 get_statuses

Get an arrayref of possible website statuses

=cut

sub get_statuses {
    STATUSES;
}

=head2 get_messages

Get a hashref of possible website status messages a.k.a. 'the reasons'

=cut

sub get_messages {
    MESSAGES;
}

=head2 get_redis_keys

Get a hashref of needed redis keys

=cut

sub get_redis_keys {
    REDIS_KEYS;
}

=head2 get_csrf_token

Generates a CSRF for this page.

=cut

sub get_csrf_token {
    my $auth_token = request()->cookies->{auth_token};

    die "Can't find auth token" unless $auth_token;

    return sha256_hex(CSRF_TOKEN_SALT . $auth_token);
}

=head2 return_bo_error

Prints out an error message.

=over 4

=item C<$error_msg> the error string to print out

=back

=cut

sub return_bo_error {
    my ($error_msg) = @_;

    BrokerPresentation("WEB SITE SETTINGS");
    code_exit_BO(_get_display_error_message($error_msg));
}

1;

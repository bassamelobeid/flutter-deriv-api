#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Config;
use BOM::Config::Runtime;
use Format::Util::Strings qw( set_selected_item );
use BOM::Backoffice::Auth;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use LandingCompany;
use Mojo::Redis2;
use JSON::MaybeUTF8;
use Syntax::Keyword::Try;
use Scalar::Util             qw(looks_like_number);
use Log::Any                 qw($log);
use BOM::Backoffice::Sysinit ();
use BOM::Database::Model::OAuth;

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('App management');

our $redis = BOM::Config::Redis->redis_ws_write();

sub redis_push {
    my ($app_id, $is_block) = @_;

    try {
        my $ids = $redis->get('app_id::blocked');

        my %block_app_ids;
        if ($ids) {

            %block_app_ids = JSON::MaybeUTF8::decode_json_utf8($ids)->%*;
        }

        if ($is_block) {
            $block_app_ids{$app_id} = 1;
        } else {
            delete $block_app_ids{$app_id};
        }
        $redis->set('app_id::blocked', JSON::MaybeUTF8::encode_json_utf8(\%block_app_ids));
        return 1;
    } catch ($e) {
        $log->warn("Redis error when recording blocked app_id - $e");
        return 0;
    }
}

my $block_app = sub {
    my $app_id = request()->param('app_id');
    if (request()->brand->get_app($app_id)->is_whitelisted || !($app_id =~ m/^[0-9]+$/)) {
        show_form_result("App ID $app_id can not be blocked.", "notify notify--warning");
    } else {
        my $oauth      = BOM::Database::Model::OAuth->new;
        my $is_revoked = $oauth->block_app($app_id);
        if ($is_revoked) {
            redis_push($app_id, 1);
            show_form_result("App $app_id has been successfully blocked.", "notify");
        } else {
            show_form_result("Unable to deactivate app $app_id", "notify notify--warning");
        }
    }
};

my $unblock_app = sub {
    my $app_id = request()->param('app_id');
    if ($app_id =~ m/^[0-9]+$/) {
        my $oauth        = BOM::Database::Model::OAuth->new;
        my $is_unblocked = $oauth->unblock_app($app_id);
        if ($is_unblocked) {
            redis_push($app_id, 0);
            show_form_result("App $app_id has been successfully activated.", "notify");
        } else {
            show_form_result("Unable to activate app $app_id", "notify notify--warning");
        }
    } else {    #input is not number
        show_form_result("App id should contains numbers only. ", "notify notify--warning");
    }
};

sub show_form_result {
    my ($text, $status) = @_;
    print "<div class=\"$status\">$text</div>";
    return;
}

=head2 get_blocked_app_operation_domain

Get the domain based app blocked value from redis

Returns a json format apps blocked from operation domain

=cut

sub get_blocked_app_operation_domain {
    return BOM::Config::Redis->redis_ws_write()->get('domain_based_apps::blocked') // '{}';
}

# Check if a staff is logged in
BOM::Backoffice::Auth::get_staff();

my $action = request()->param('action');
if ($action and $action eq 'BLOCK APP') {
    $block_app->();
} elsif ($action and $action eq 'UNBLOCK APP') {
    $unblock_app->();
} elsif ($action and $action eq 'BLOCK APPS IN DOMAIN') {
    my $block_apps = request()->param('block_app_operation_domain');
    try {
        my %decoded = %{JSON::MaybeXS->new->decode($block_apps)};

        foreach my $domain (keys %decoded) {
            if (ref($decoded{$domain}) ne 'ARRAY') {
                die "Entered string is not in expected format";
            } else {
                foreach my $app_id ($decoded{$domain}->@*) {
                    if (!looks_like_number($app_id)) {
                        die "App Id should be numeric value";
                    }
                }
            }
        }

        $redis->set('domain_based_apps::blocked', $block_apps);
        $redis->publish(
            'introspection',
            encode_json_utf8({
                    command => 'block_app_in_domain',
                    channel => 'introspection_response'
                }));
        show_form_result("Block apps based on domain has been updated successfully", "notify");
    } catch ($e) {
        show_form_result("JSON string provided is not valid: $e", "notify notify--warning");
    }
} elsif ($action and $action eq 'MODIFY OFFICIAL APPS') {
    my $official_apps = request()->param('official_app');
    try {
        my $result = set_official_apps_in_redis();
        if (defined $result) {
            show_form_result("official apps has been updated successfully", "notify");
        } else {
            show_form_result("No apps found to modify", "notify");
        }
    } catch ($e) {
        show_form_result("some error occured while modifying official apps  $e", "notify notify--warning");
    }
}

# deactivate app
if (BOM::Backoffice::Auth::has_authorisation(['Marketing'])) {
    Bar(
        'Deactivate app',
        {
            container_class => 'card',
            title_class     => 'card__label toggle'
        });
    print qq~
        <p>Revoke app ID</p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="post">
            <label for="app_id_revoke">App ID:</label>
            <input type="number" id="app_id_revoke" name="app_id" />
            <input type="submit" class="btn btn--primary" name="action" value="BLOCK APP" onclick="return confirm('Are you sure you want to revoke the app?')">
        </form>~;
}

# activate app
if (BOM::Backoffice::Auth::has_authorisation(['Marketing'])) {
    Bar(
        'Activate app',
        {
            container_class => 'card',
            title_class     => 'card__label toggle'
        });
    print qq~
        <p>Activate app ID</p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="get">
            <label for="app_id_activate">App ID:</label>
            <input type="number" id="app_id_activate" name="app_id" />
            <input type="submit" class="btn btn--primary" name="action" value="UNBLOCK APP" onclick="return confirm('Are you sure you want to activate the app?')">
        </form>~;
}

# block app using certain operation domain
if (BOM::Backoffice::Auth::has_authorisation(['Marketing'])) {
    Bar(
        'Block apps',
        {
            container_class => 'card',
            title_class     => 'card__label toggle'
        });
    print qq~
        <p>Block apps in certain opertation domain (red, blue, green etc). Expected format example: {
        "red": [1],
        "blue": [24269, 23650]
        }
        </p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="post">
            <label for="block_app_operation_domain">Blocked App IDs:</label>
            <textarea id="block_app_operation_domain" rows="3" cols="30" name="block_app_operation_domain" placeholder="{}">~
        . get_blocked_app_operation_domain() . qq~</textarea>
            <input type="submit" class="btn btn--primary" name="action" value="BLOCK APPS IN DOMAIN" onclick="return confirm('Are you sure you want to block the app(s) in the domain(s)?'">
            </form>~;
}

=head2 get_official_apps

Below function will fill the read-only text area to manage all apps (official) added into Database from redis

Returns a join array for all official apps

=cut

sub get_official_apps {
    my $official_apps = $redis->smembers('domain_based_apps::official');
    return scalar(@$official_apps) ? join(",", @$official_apps) : '{}';
}

=head2 set_official_apps_in_redis

Below function will fill the read-only text area to manage all apps (official) added into Database

Returns a join array for all official apps

=cut

sub set_official_apps_in_redis {
    #always fetch latest apps from Database
    my $oauth_model = BOM::Database::Model::OAuth->new;
    my $apps        = $oauth_model->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT app_id FROM oauth.official_apps ");
        });
    my @official_app_ids = map { @$_ } @$apps;
    # Delete existing entries from Redis set (this is to avoid any decommission app id already be in redis set even after removal from DB)
    $redis->del('domain_based_apps::official');
    return $redis->sadd('domain_based_apps::official', @official_app_ids);
}

# add official app
if (BOM::Backoffice::Auth::has_authorisation(['IT', 'Marketing'])) {
    Bar(
        'Official apps',
        {
            container_class => 'card',
            title_class     => 'card__label toggle'
        });
    print qq~
        <p>Official apps allowed for all opertation domain (red, blue, green etc). Expected format example: [1223,45434,122,1]</p>
        <p>This is a read-only field only click MODIFY OFFICIAL APPS to reflect latest official app list from system</p>
        <p><strong>NOTE FOR DEVOPS: binary_websocket_api restart is required after modifying official apps </strong></p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="post">
            <label for="official_app">Official App IDs:</label>
            <textarea id="official_app" rows="3" cols="30" name="official_app" placeholder="[]" readonly>~
        . get_official_apps() . qq~</textarea>
            <input type="submit" class="btn btn--primary" name="action" value="MODIFY OFFICIAL APPS" onclick="return confirm('Are you sure you want to add the app(s)?'">
            </form>~;
}
code_exit_BO();

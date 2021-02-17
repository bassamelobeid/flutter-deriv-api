#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Config;
use BOM::Config::Runtime;
use Format::Util::Strings qw( set_selected_item );
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use LandingCompany;
use Mojo::Redis2;
use Binary::WebSocketAPI::v3::Instance::Redis qw| check_connections ws_redis_master |;
use JSON::MaybeUTF8;

use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('App management');

sub redis_push {
    my ($app_id, $is_block) = @_;
    my $redis = ws_redis_master();

    $redis->get(
        'app_id::blocked',
        sub {
            my ($redis, $err, $ids) = @_;
            if ($err) {
                warn "Error reading blocked app IDs from Redis: $err\n";
                return;
            }
            return 0 if $ids;
            my %block_app_ids = %{JSON::MaybeUTF8::decode_json_utf8($ids)};
            if ($is_block) {
                $block_app_ids{$app_id} = 1;
            } else {
                delete $block_app_ids{$app_id};
            }
            $redis->set(
                'app_id::blocked' => JSON::MaybeUTF8::encode_json_utf8(\%block_app_ids),
                sub {
                    my ($redis, $err) = @_;
                    warn "Redis error when recording blocked app_id - $err";
                    return;
                });
        });
    return 1;
}

my $block_app = sub {
    my $app_id = request()->param('app_id');
    if (request()->brand->is_app_whitelisted($app_id) || !($app_id =~ m/^[0-9]+$/)) {
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

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();

my $action = request()->param('action');
if ($action and $action eq 'BLOCK APP') {
    $block_app->();
} elsif ($action and $action eq 'UNBLOCK APP') {
    $unblock_app->();
}

# deactivate app
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    Bar(
        'Deactivate app',
        {
            container_class => 'card',
            title_class     => 'card__label'
        });
    print qq~
        <p>Revoke app ID</p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="post">
            <label for="app_id_revoke">App ID:</label>
            <input type="number" id="app_id_revoke" name="app_id" />
            <input type="submit" class="btn btn--red" name="action" value="BLOCK APP" onclick="return confirm('Are you sure you want to revoke the app?')">
        </form>~;
}

# activate app
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    Bar(
        'Activate app',
        {
            container_class => 'card',
            title_class     => 'card__label'
        });
    print qq~
        <p>Activate app ID</p>
        <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="get">
            <label for="app_id_activate">App ID:</label>
            <input type="number" id="app_id_activate" name="app_id" />
            <input type="submit" class="btn btn--red" name="action" value="UNBLOCK APP" onclick="return confirm('Are you sure you want to activate the app?')">
        </form>~;
}

code_exit_BO();

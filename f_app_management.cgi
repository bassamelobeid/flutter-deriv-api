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
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);

use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

PrintContentType();

BrokerPresentation('App management');

our $redis = ws_redis_master();

sub redis_push {
    my ($app_id, $is_block) = @_;

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

=head2 get_blocked_app_operation_domain

Get the domain based app blocked value from redis

Returns a json format apps blocked from operation domain

=cut

sub get_blocked_app_operation_domain {
    return $redis->get('domain_based_apps::blocked') // '{}';
}

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();

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
}

# deactivate app
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
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
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
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
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
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

code_exit_BO();

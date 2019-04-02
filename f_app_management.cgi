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
use Brands;
use Mojo::Redis2;
use Binary::WebSocketAPI::v3::Instance::Redis qw| check_connections ws_redis_master |;
use JSON::MaybeUTF8;

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

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
    if (Brands->new()->is_app_whitelisted($app_id) || !($app_id =~ m/^[0-9]+$/)) {
        show_form_result("App ID $app_id can not be blocked.", "error");
    } else {
        my $oauth      = BOM::Database::Model::OAuth->new;
        my $is_revoked = $oauth->block_app($app_id);
        if ($is_revoked) {
            redis_push($app_id, 1);
            show_form_result("App $app_id has been successfully blocked.", "success");
        } else {
            show_form_result("Unable to deactivate app $app_id", "error");
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
            show_form_result("App $app_id has been successfully activated.", "success");
        } else {
            show_form_result("Unable to activate app $app_id", "error");
        }
    } else {    #input is not number
        show_form_result("App id should contains numbers only. ", "error");
    }
};

sub show_form_result {
    my ($text, $status) = @_;
    print "<style>#msg {display:block;font-size:1.5em;padding:1em} .success{background: lightgreen} .error{background: lightsalmon}</style>";
    print "<div class=\"$status\" id=\"msg\">$text</div>";
    return 1;
}

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();
PrintContentType();

my $action = request()->param('action');
if ($action and $action eq 'BLOCK APP') {
    $block_app->();
} elsif ($action and $action eq 'UNBLOCK APP') {
    $unblock_app->();
}

BrokerPresentation('App management');
print "<center>";

# deactive app
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
	<table class="GreenDarkCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreenLabel">
				<td class="whitelabel" colspan="2">Deactive app</td>
			</tr>
			<tr>
				 <td align="center" width="50%">
                    <p><b>REVOKING APP ID</b></p>
                    <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="post"><font size=2>
                        <label for="app_id"><b>APP ID: </b></label>
                        <input type="number" id="app_id" name="app_id"></input>
                        <input type="submit" name="action" value="BLOCK APP" onclick="return confirm('Are you sure you want to revoke the app?')">
                    </form>
                </td>
			</tr>
		</tbody>
	</table>~;
}

# activate app
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
	<table class="GreenDarkCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreenLabel">
				<td class="whitelabel" colspan="2">Activate app</td>
			</tr>
			<tr>
				 <td align="center" width="50%">
                    <p><b>Activate APP ID</b></p>
                    <form action="~ . request()->url_for('backoffice/f_app_management.cgi') . qq~" method="get"><font size=2>
                        <label for="app_id"><b>APP ID: </b></label>
                        <input type="number" id="app_id" name="app_id"></input>
                        <input type="submit" name="action" value="UNBLOCK APP" onclick="return confirm('Are you sure you want to activate the app?')">
                    </form>
                </td>
			</tr>
		</tbody>
	</table>~;
}

code_exit_BO();


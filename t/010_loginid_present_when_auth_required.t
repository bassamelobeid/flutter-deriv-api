use strict;
use warnings;

use Test::More;
use Test::Warnings;

use Path::Tiny;
use File::Basename;
use Binary::WebSocketAPI::Actions qw(actions_config);

use JSON;
use List::Util qw(any);

my $base_path = 'config/v3';
my $dir       = path($base_path);
my $json      = JSON->new;

# these calls require authorization but only return user data; i.e. the response is the same for a user regards which loginid they authorize with
my @user_level_calls = qw(
    account_list
);

# These actions are forwarded by the websocket (instead of handled by RPC) and need a token.
my @forwarded_actions = qw(
    proposal
    exchange_rates
    crypto_estimations
    trading_platform_asset_listing
);

# Next to schemas that are auth_required, there are actions that are not auth_required, but need a token.
# For example, payment_methods is not auth_required, but needs a token and therefore a loginid.
my @actions_with_token = get_actions_with_token();

subtest 'Check that loginid in present in all the schemas that are auth_required or need a token.' => sub {
    for (sort $dir->children) {
        my $request   = basename($_);
        my $send_file = $dir . "/" . $request . "/" . "send.json";

        my $data          = $json->decode(path($send_file)->slurp_utf8);
        my $auth_required = $data->{auth_required};
        my $loginid       = $data->{properties}->{loginid};

        # As user can add multiple authentication tokens in the authorize call, each schema must have loginid when auth_required is true
        # or has a token on the stash. This to select the correct token to use.
        if (auth_required($request, $auth_required, \@actions_with_token, \@forwarded_actions)) {
            ok(defined $loginid, "$request has loginid. Each schema must have loginid when auth_required or has token on stash.");
        } else {
            # There should be no loginid for schemas that doesn't require authentication.
            ok(!defined $loginid, "$request has no loginid as no auth is required nor uses a token.");
        }
    }
};

# Authentication is required when:
# - auth_required is true in the schema send.json of the action
# - the action has a token on the stash (defined in actions_config)
# - the action is forwarded by the websocket and requires authentication in the forwarded action
sub auth_required {
    my ($request, $auth_required, $actions_with_token, $forwarded_actions) = @_;

    return if any { $_ eq $request } @user_level_calls;

    my $has_stash_token = grep(/^$request$/, $actions_with_token->@*);
    return $auth_required || $has_stash_token || grep(/^$request$/, $forwarded_actions->@*);
}

# These actions require a token on the stash.
sub get_actions_with_token {
    my $actions_config = Binary::WebSocketAPI::Actions::actions_config();
    my @actions_with_token;

    for my $config ($actions_config->@*) {
        my $action       = $config->[0];
        my $params       = $config->[1] if @$config > 1;
        my $stash_params = $params->{stash_params};

        push @actions_with_token, $action if $stash_params && grep(/^token$/, $stash_params->@*);
    }

    return @actions_with_token;
}

done_testing;

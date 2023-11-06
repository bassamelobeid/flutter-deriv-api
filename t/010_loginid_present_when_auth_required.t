use strict;
use warnings;

use Test::More;
use Test::Warnings;

use Path::Tiny;
use File::Basename;
use Binary::WebSocketAPI::Actions qw(actions_config);

use JSON;
use List::Util qw(first all);

my $base_path = 'config/v3';
my $dir       = path($base_path);
my $json      = JSON->new;

# Next to schemas that are auth_required, there are actions that are not auth_required, but need a token.
# For example, payment_methods is not auth_required, but needs a token and therefore a loginid.
my @actions_with_token = get_actions_with_token();

for (sort $dir->children) {
    my $request   = basename($_);
    my $send_file = $dir . "/" . $request . "/" . "send.json";

    my $data              = $json->decode(path($send_file)->slurp_utf8);
    my $auth_required     = $data->{auth_required};
    my $loginid           = $data->{properties}->{loginid};
    my $has_stash_token   = grep(/^$request$/, @actions_with_token);
    my @forwarded_actions = get_actions_forwarded_with_tokens();
    my @exclude_phase1    = exclude_phase1();

    # As user can add multiple authentication tokens in the authorize call, each schema must have loginid when auth_required is true
    # or has a token on the stash. This to select the correct token to use.
    if (($auth_required || $has_stash_token || grep(/^$request$/, @forwarded_actions)) && !grep(/^$request$/, @exclude_phase1)) {
        ok(defined $loginid, "$request has loginid. Each schema must have loginid when auth_required or has token on stash");
    } else {
        ok(!defined $loginid,
            "$request has no loginid as no auth is required nor uses a token (or loginid support for this request is excluded from phase 1)");
    }
}

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

sub get_actions_forwarded_with_tokens {
    return qw(
        proposal
        exchange_rates
        crypto_estimations
        trading_platform_asset_listing
    );
}

sub exclude_phase1 {
    return qw(
        p2p_advert_create
        p2p_advert_info
        p2p_advert_list
        p2p_advert_update
        p2p_advertiser_adverts
        p2p_advertiser_create
        p2p_advertiser_info
        p2p_advertiser_list
        p2p_advertiser_payment_methods
        p2p_advertiser_relations
        p2p_advertiser_update
        p2p_chat_create
        p2p_order_cancel
        p2p_order_confirm
        p2p_order_create
        p2p_order_dispute
        p2p_order_info
        p2p_order_list
        p2p_order_review
        p2p_payment_methods
        p2p_ping
        p2p_settings
        paymentagent_create
        paymentagent_details
        paymentagent_list
        paymentagent_transfer
        paymentagent_withdraw
        paymentagent_withdraw_justification
        mt5_deposit
        mt5_get_settings
        mt5_login_list
        mt5_new_account
        mt5_password_change
        mt5_password_check
        mt5_password_reset
        mt5_withdrawal
        trading_platform_accounts
        trading_platform_available_accounts
        trading_platform_deposit
        trading_platform_investor_password_change
        trading_platform_investor_password_reset
        trading_platform_new_account
        trading_platform_password_change
        trading_platform_password_reset
        trading_platform_withdrawal
    );
}

done_testing;

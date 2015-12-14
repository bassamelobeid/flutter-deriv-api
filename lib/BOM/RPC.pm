package BOM::RPC;

use Mojo::Base 'Mojolicious';

use BOM::Platform::Runtime;
use BOM::Platform::Context ();
use BOM::Platform::Context::Request;
use MojoX::JSON::RPC::Service;

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('rpc');
    $app->plugin('Config');

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    foreach my $fun (qw(
        'BOM::RPC::v3::Accounts::payout_currencies'
        'BOM::RPC::v3::Accounts::landing_company'
        'BOM::RPC::v3::Accounts::landing_company_details'
        'BOM::RPC::v3::Accounts::statement'
        'BOM::RPC::v3::Accounts::profit_table'
        'BOM::RPC::v3::Accounts::send_realtime_balance'
        'BOM::RPC::v3::Accounts::balance'
        'BOM::RPC::v3::Accounts::get_account_status'
        'BOM::RPC::v3::Accounts::change_password'
        'BOM::RPC::v3::Accounts::cashier_password'
        'BOM::RPC::v3::Accounts::get_settings'
        'BOM::RPC::v3::Accounts::set_settings'
        'BOM::RPC::v3::Accounts::get_self_exclusion'
        'BOM::RPC::v3::Accounts::set_self_exclusion'
        'BOM::RPC::v3::Accounts::api_token'
        'BOM::RPC::v3::Authorize::authorize'
        'BOM::RPC::v3::Cashier::get_limits'
        'BOM::RPC::v3::Cashier::paymentagent_list'
        'BOM::RPC::v3::Cashier::paymentagent_transfer'
        'BOM::RPC::v3::Cashier::paymentagent_withdraw'
        'BOM::RPC::v3::Cashier::transfer_between_accounts'
        'BOM::RPC::v3::Contract::validate_symbol'
        'BOM::RPC::v3::Contract::validate_license'
        'BOM::RPC::v3::Contract::validate_underlying'
        'BOM::RPC::v3::Contract::prepare_ask'
        'BOM::RPC::v3::Contract::get_ask'
        'BOM::RPC::v3::Contract::get_bid'
        'BOM::RPC::v3::MarketDiscovery::trading_times'
        'BOM::RPC::v3::MarketDiscovery::asset_index'
        'BOM::RPC::v3::MarketDiscovery::active_symbols'
        'BOM::RPC::v3::NewAccount::new_account_virtual'
        'BOM::RPC::v3::NewAccount::verify_email'
        'BOM::RPC::v3::NewAccount::new_account_real'
        'BOM::RPC::v3::NewAccount::new_account_maltainvest'
        'BOM::RPC::v3::Offerings::contracts_for'
        'BOM::RPC::v3::PortfolioManagement::portfolio'
        'BOM::RPC::v3::Static::residence_list'
        'BOM::RPC::v3::Static::states_list'
        'BOM::RPC::v3::TickStreamer::ticks_history'
        'BOM::RPC::v3::TickStreamer::ticks'
        'BOM::RPC::v3::TickStreamer::candles'
        'BOM::RPC::v3::Transaction::buy'
        ))
    {
        $app->plugin('json_rpc_dispatcher' => {services => {'/jsonrpc' => MojoX::JSON::RPC::Service->new->register($fun, \&$fun)}});
    }

    return;
}

1;

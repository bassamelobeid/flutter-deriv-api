package BOM::RPC;

use Mojo::Base 'Mojolicious';

use BOM::Platform::Runtime;
use BOM::Platform::Context ();
use BOM::Platform::Context::Request;
use MojoX::JSON::RPC::Service;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Transaction;

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('rpc');
    $app->plugin('Config' => {file => $ENV{RPC_CONFIG} || '/etc/rmg/rpc.conf'});

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    $app->plugin(
        'json_rpc_dispatcher' => {
            services => {
                '/landing_company' => MojoX::JSON::RPC::Service->new->register('landing_company', \&BOM::RPC::v3::Accounts::landing_company),
                '/residence_list'  => MojoX::JSON::RPC::Service->new->register('residence_list',  \&BOM::RPC::v3::Static::residence_list),
                '/states_list'     => MojoX::JSON::RPC::Service->new->register('states_list',     \&BOM::RPC::v3::Static::states_list),
                '/ticks_history'   => MojoX::JSON::RPC::Service->new->register('ticks_history',   \&BOM::RPC::v3::TickStreamer::ticks_history),
                '/buy'             => MojoX::JSON::RPC::Service->new->register('buy',             \&BOM::RPC::v3::Transaction::buy),
                '/sell'            => MojoX::JSON::RPC::Service->new->register('sell',            \&BOM::RPC::v3::Transaction::sell),
            },
            exception_handler => sub {
                my ($dispatcher, $err, $m) = @_;
                $dispatcher->app->log->error(qq{Internal error: $err});
                $m->invalid_request('Invalid request');
                return;
            }
        });

    return;
}

1;

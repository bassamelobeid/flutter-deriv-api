package BOM::RPC;

use Mojo::Base 'Mojolicious';

use BOM::Platform::Runtime;
use BOM::Platform::Context ();
use BOM::Platform::Context::Request;
use MojoX::JSON::RPC::Service;
use BOM::RPC::v3::Accounts;

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('rpc');
    $app->plugin('Config' =>  { file => $ENV{RPC_CONFIG} || '/etc/rmg/rpc.conf' });

    my $log = $app->log;

    my $signature = "Binary.com RPC";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    $app->plugin(
        'json_rpc_dispatcher' => {
            services => {
                '/landing_company' => MojoX::JSON::RPC::Service->new->register('landing_company', \&BOM::RPC::v3::Accounts::landing_company),
            }});

    return;
}

1;

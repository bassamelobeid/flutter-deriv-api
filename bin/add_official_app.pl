#!/etc/rmg/bin/perl

use strict;
use warnings;
use Getopt::Long      qw( GetOptions );
use Log::Any::Adapter qw(DERIV), stdout => 'text';
use Log::Any          qw($log);
use BOM::Database::Model::OAuth;

my (%opt, $app_id, $is_primary, $is_internal);

our $VERSION = '1.1';

my $USAGE = "Usage: $0 --appid=<application ID> --primary=<is it primary website> --inetrnal=<is it internal app> \n
 parameters appid, primary are required.";

#perl bin/add_official_app.pl --appid= --primary=1 --inetrnal=0

my $data = get_all_options();
add_official_app($data);

sub add_official_app {
    my $args     = shift;
    my $oauth    = BOM::Database::Model::OAuth->new;
    my $app_id   = $args->{appid};
    my $primary  = $args->{primary};
    my $internal = $args->{internal} // 0;

    my $app = $oauth->add_official_app($app_id, $primary, $internal);

    # log a string and some data;
    $log->info(
        "app added to official apps ",
        {
            app_id             => $app->{app_id},
            is_primary_website => $app->{is_primary_website},
            is_internal        => $app->{is_internal},
        });

    return $app;
}

sub get_all_options {

    %opt = (
        primary  => 0,
        internal => 0,
    );

    GetOptions(\%opt, 'appid=i', 'primary=i', 'internal=i', 'help|h',) or die;

    if ($opt{help} or !$opt{appid}) {    ## no critic
        $log->fatal("$USAGE");
        exit 1;
    }

    $app_id      = $opt{appid};
    $is_primary  = $opt{primary};
    $is_internal = $opt{internal};

    return \%opt;
}


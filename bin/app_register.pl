#!/etc/rmg/bin/perl

use strict;
use Getopt::Long      qw( GetOptions );
use Log::Any::Adapter qw(DERIV), stdout => 'text';
use Log::Any          qw($log);
use BOM::Database::Model::OAuth;
use BOM::RPC::v3::Utility;

my (%opt, $verbose, $quiet, $name, $redirect_uri, $verification_uri, $homepage, $github, $appstore, $googleplay, $app_markup_percentage, $scopes,
    $user_id);

our $VERSION = '1.1';

my $USAGE =
    "Usage: $0 --name=<app name> --redirecturi=<app redirect> --verificationuri=<app verification> --homepage=<app homepage> --github=<app github> --appstore=<app appstore>  --googleplay=<app googleplay> --percentage=<app markup percentage> --scopes=<scopes> --userid=<binary_user_id>\n
 parameters name, redirecturi, scopes and userid are required.";

my $data = get_all_options();
app_register($data);

sub app_register {
    my $args  = shift;
    my $oauth = BOM::Database::Model::OAuth->new;

    my $name                  = $args->{name};
    my $scopes                = $args->{scopes};
    my $homepage              = $args->{homepage}        // '';
    my $github                = $args->{github}          // '';
    my $appstore              = $args->{appstore}        // '';
    my $googleplay            = $args->{googleplay}      // '';
    my $redirect_uri          = $args->{redirecturi}     // '';
    my $verification_uri      = $args->{verificationuri} // '';
    my $app_markup_percentage = $args->{percentage}      // 0;
    my $user_id               = $args->{userid};

    my $error_sub = sub {
        my ($error) = @_;
        return BOM::RPC::v3::Utility::create_error({
            code              => 'AppRegister',
            message_to_client => $error,
        });
    };

    if (my $err = __validate_redirect_uri($redirect_uri, $app_markup_percentage)) {
        $log->fatal("redirect uri is not valid");
        return $error_sub->($err);
    }

    if (my $err = __validate_app_links($homepage, $github, $appstore, $googleplay, $redirect_uri, $verification_uri)) {
        $log->fatal("link or links provided is not valid");
        return $error_sub->($err);
    }

    if ($oauth->is_name_taken($user_id, $name)) {
        return $log->fatal("The name is taken.");
    }

    my $payload = {
        user_id               => $user_id,
        name                  => $name,
        scopes                => $scopes,
        homepage              => $homepage,
        github                => $github,
        appstore              => $appstore,
        googleplay            => $googleplay,
        redirect_uri          => $redirect_uri,
        verification_uri      => $verification_uri,
        app_markup_percentage => $app_markup_percentage
    };

    my $app = $oauth->create_app($payload);
    delete $payload->{user_id};

    # log a string and some data
    $log->info(
        "app registered ",
        {
            app_id           => $app->{app_id},
            name             => $app->{name},
            redirect_uri     => $app->{redirect_uri},
            verification_uri => $app->{verification_uri},
            homepage         => $app->{homepage},
            github           => $app->{github},
            active           => $app->{active},
            scopes           => $app->{scopes},
        });

    return $app;
}

sub __validate_redirect_uri {
    my ($redirect_uri)          = shift // '';
    my ($app_markup_percentage) = shift // 0;

    if (int($app_markup_percentage) > 0 && $redirect_uri eq '') {
        return localize('Please provide redirect url.');
    }

    return;
}

sub __validate_app_links {
    my @sites = @_;
    my $validation_error;

    for (grep { length($_) } @sites) {
        next if $_ =~ m{^https?://play\.google\.com/store/apps/details\?id=[\w.]+$};
        $validation_error = BOM::RPC::v3::Utility::validate_uri($_);
        return $validation_error if $validation_error;
    }

    return;
}

sub get_all_options {

    GetOptions(
        \%opt,        'name=s',       'redirecturi=s', 'verificationuri=s', 'homepage=s', 'github=s',
        'appstore=s', 'googleplay=s', 'percentage=f',  'scopes=s@',         'userid=i',   'help|h',
    ) or die;

    if ($opt{help} or !$opt{name} or !$opt{redirecturi} or !$opt{scopes} or !$opt{userid}) {    ## no critic
        $log->fatal("$USAGE");
        exit 1;
    }

    $name                  = $opt{name};
    $redirect_uri          = $opt{redirecturi};
    $verification_uri      = $opt{verificationuri};
    $homepage              = $opt{homepage};
    $github                = $opt{github};
    $appstore              = $opt{appstore};
    $googleplay            = $opt{googleplay};
    $app_markup_percentage = $opt{percentage};
    $scopes                = $opt{scopes};
    $user_id               = $opt{userid};

    return \%opt;
}


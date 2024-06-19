use strict;
use Getopt::Long qw( GetOptions );
use Log::Any     qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');
use BOM::Database::Model::OAuth;
use Syntax::Keyword::Try;
use YAML::XS;
use Text::Trim;

my $USAGE = "Usage: $0 --file=<yaml file path> \nparameter file is required.";

=head1 DESCRIPTION

Ths script is used to create app token for the given app_id in oauth.app_token table in auth01 database.

The input YAML file should contain app_id and app_token (e.g):

app_id: 1234
app_token: abcd1234

=cut

my %opt;
my $config;

GetOptions(\%opt, 'file=s', 'help|h') or die;
if ($opt{help} or !$opt{file}) {
    $log->fatal($USAGE);
    exit 1;
}

try {
    $config = YAML::XS::LoadFile($opt{file});
} catch ($e) {
    $log->fatalf('Failed due to %s', $e);
    exit 1;
}

if (!$config->{app_id} || !$config->{app_token}) {
    $log->fatal('app_id or app_token is missing/not populated in the file: %s.', $opt{file});
    exit 1;
}

if ($config->{app_id} !~ m/^[0-9]+$/) {
    $log->fatal("Invalid format for app_id.");
    exit 1;
}
if ($config->{app_token} !~ m/^[a-zA-Z0-9]+$/) {
    $log->fatal("Invalid format for app_token.");
    exit 1;
}

my $oauth     = BOM::Database::Model::OAuth->new;
my $app_id    = trim($config->{app_id});
my $app_token = trim($config->{app_token});
if (my @tokens = $oauth->get_app_tokens($app_id)->@*) {
    $log->fatalf('Token for app_id: %s already exists!', $app_id);
    exit 1;
}

$log->infof('app_id: %s',    $app_id);
$log->infof('app_token: %s', $app_token);
$log->infof('Check if the information is correct. Shall we proceed (Y/N) ?');
my $answer = <STDIN>;
chomp $answer;
if ($answer !~ m/^y$/i) {
    $log->info('Exited without making any changes!');
    exit 1;
}
try {
    $oauth->create_app_token($app_id, $app_token);
    $log->infof('App token for app_id: %s added successfully!', $app_id);
} catch ($e) {
    $log->fatalf('Token creation failed due to %s', $e);
}

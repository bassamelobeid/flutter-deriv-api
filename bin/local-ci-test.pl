#!/bin/env perl
use strict;
use warnings;
use YAML qw(LoadFile DumpFile);
use Path::Tiny;

# TODO run tests concurrently ?
# TODO parse output of circleci, and exit 1 if there is error.

=head1 NAME

ci-test - The wrapper to run circleCI test locally

=head1 SYNOPSIS

     # single job
     ci-test.pl circleci-config-file job-name
     # all jobs
     ci-test.pl circleci-config-file
     # run tests under current directory
     ci-test.pl

=head1 DESCRIPTION

Run circleci test locally.

This script assume you put all dependency repos in one directory, say, /home/somebody/git/regentmarkets.
Please make sure all dependency repos are there. Don't forget I<travis-scripts>. It is required when starting services in docker.

When you test a repo, you can run script as:

    ci-test.pl repo/.circleci/config.yml

The script will map repo/.. to docker's /home/git/regentmarkets. And then test script can access those codes. It will not do I<git pull> on your local directory.
So it's your task to update those repos.

=cut

my $config_file = shift || '.circleci/config.yml';
my $job         = shift;
$config_file = path($config_file)->absolute;
my $config = LoadFile($config_file->stringify);
for my $job (values $config->{jobs}->%*) {
    my $steps     = $job->{steps};
    my $new_steps = [];
    for my $step_i (0 .. $steps->$#*) {
        my $step = $steps->[$step_i];
        (push @$new_steps, $step && next) unless ref($step) eq 'HASH';
        my ($step_name) = keys $step->%*;
        # we don't want to store_test_results, it will cause fail in the last step.
        next if $step_name eq 'store_test_results';
        if ($step_name eq 'run') {
            #We don't want to change .proverc locally because that will cause permission error -- nobody in docker vs. normal user outside.
            $step->{$step_name}{command} =~ s/[^\n]*TAP::Formatter::JUnit[^\n]*\n//s;
        }
        push @$new_steps, $step;
    }
    $job->{steps} = $new_steps;
}

my @jobs = $job ? ($job) : (keys $config->{jobs}->%*);

# circleci will map volume pwd:pwd (here pwd means the current working dir);
# and then will look for config file with same path,
# So to avoid conflicts between many docker instance, we put config file to a random temp directory
my $tmp_dir         = Path::Tiny->tempdir;
my $new_config_file = $tmp_dir->child('config.yml');
DumpFile("$new_config_file", $config);
# current work dir should be in path of config file, because circleCI will do a volume map pwd:pwd and access config file.
chdir($new_config_file->parent->stringify);

# We assume the config file is under regentmarkets/$repo/.circleci/config.yml
my $regentmarkets_dir = $config_file->parent(3);
my $repo_name         = $config_file->parent(2)->basename;
my @command           = (
    qw(circleci local execute -e NO_REPO_CHECK=1),
    '-v' => "$regentmarkets_dir:/home/git/regentmarkets",
    '-c' => $new_config_file->stringify,
    '-e' => "CIRCLE_PROJECT_REPONAME=$repo_name"
);

for my $job (@jobs) {
    push @command, '--job' => $job;
    warn "Running command @command\n";
    system(@command);
}

#chdir to /tmp, so that the created tempdir can be dropped.
chdir('/tmp');

package BOM::MyAffiliates::Reporter;

=head1 NAME

BOM::MyAffiliates::Reporter;

=head1 DESCRIPTION

Parent class for all affiliates reports we generate

=cut

use Moose;
use Path::Tiny;
use IO::Async::Loop;
use Amazon::S3::SignedURLGenerator;
use YAML::XS qw(LoadFile);
use Net::Async::Webservice::S3;
use List::Util qw(any first);

use Brands;

use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Database::DataMapper::MyAffiliates;

use feature 'state';

use constant NOT_IMPLEMENTED => "Not implemented %s %s %s";

has system_directory_path => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_system_directory_path {
    return path(BOM::Config::Runtime->instance->app_config->system->directory->db);
}

has parent_directory => (
    is      => 'ro',
    default => 'myaffiliates'
);

has brand => (
    is       => 'ro',
    isa      => 'Brands',
    required => 1,
);

has processing_date => (
    is       => 'ro',
    isa      => 'Date::Utility',
    required => 1,
);

has include_headers => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

has exclude_broker_codes => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { ['MF'] },
);

# Required methods
# these methods must been declared in child classes
# or his respective parent, if not implemented we need to die.

sub output_file_prefix {
    die sprintf(NOT_IMPLEMENTED, caller);
}

sub headers {
    die sprintf(NOT_IMPLEMENTED, caller);
}

sub activity {
    die sprintf(NOT_IMPLEMENTED, caller);
}

# common methods

sub database_mapper {
    my $myaffiliates_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
    });
    $myaffiliates_data_mapper->db->dbh->do("SET statement_timeout TO " . 900_000);

    return $myaffiliates_data_mapper;
}

sub sub_directory {
    return shift->brand->name;
}

sub headers_data {
    my $self = shift;

    my $csv = Text::CSV->new;
    $csv->combine($self->headers());
    return $csv->string;
}

sub _config {
    my $self = shift;

    state $config = LoadFile('/etc/rmg/third_party.yml')->{myaffiliates};
    return $config;
}

sub upload_content {
    my ($self, %args) = @_;

    my $config = $self->_config();

    my $loop = IO::Async::Loop->new;
    my $s3   = Net::Async::Webservice::S3->new(
        access_key => $config->{aws_access_key_id},
        secret_key => $config->{aws_secret_access_key},
        bucket     => $config->{aws_bucket},
        ssl        => 1,
    );
    $loop->add($s3);

    $s3->put_object(
        key   => $args{output_zip}{name},
        value => path($args{output_zip}{path})->slurp,
    )->get;

    return;
}

sub download_url {
    my ($self, %args) = @_;

    $self->upload_content(%args);

    my $config = $self->_config();

    return Amazon::S3::SignedURLGenerator->new(
        aws_access_key_id     => $config->{aws_access_key_id},
        aws_secret_access_key => $config->{aws_secret_access_key},
        prefix                => "https://$config->{aws_bucket}.s3.amazonaws.com/",
        expires               => 24 * 3600
    )->generate_url('GET', $args{output_zip}{name});
}

sub output_file_name {
    my $self = shift;
    return $self->output_file_prefix() . $self->processing_date->date_yyyymmdd . '.csv';
}

sub directory_path {
    my $self = shift;
    return $self->system_directory_path->child($self->parent_directory)->child($self->sub_directory());
}

sub output_file_path {
    my $self = shift;
    return $self->directory_path()->child($self->output_file_prefix() . $self->processing_date->date_yyyymmdd . '.csv');
}

sub send_report {
    my ($self, %args) = @_;

    my $brand = $self->brand;
    # email CSV out for reporting purposes
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('affiliates'),
        subject => $brand->name . ': ' . $args{subject},
        message => $args{message},
        $args{attachment} ? (attachment => $args{attachment}) : (),
    });

    return undef;
}

sub format_data {
    my $self = shift;
    my $data = shift;

    return unless $data;

    chomp $data;
    $data .= "\n";

    return $data;
}

=head2 get_apps_by_brand

This return apps by brand

It has special case for brand 'binary' - details below

In past we used to send single file to myaffiliates containing
all clients activities.
Now, we need to send per brand and we don't have proper segregation
of client activity by brand, the closest we have is app id.

For all brands except 'binary' brand we will only send data
for app id listed in brand config.

For binary, as we use to send data for all the
apps including third party apps, so for binary we will
exclude other brands apps.

=cut

sub get_apps_by_brand {
    my $self = shift;

    my $result = {
        exclude_apps => undef,
        include_apps => undef,
    };

    my $allowed_brand_names = $self->brand->allowed_names();
    if ($self->brand->name eq 'binary' and any { 'binary' eq $_ } @$allowed_brand_names) {
        for (grep { $_ ne 'binary' } @$allowed_brand_names) {
            my $allowed_name = $_;
            my $brand        = Brands->new(name => $allowed_name);
            push @{$result->{exclude_apps}}, keys %{$brand->whitelist_apps()};
        }
    } else {
        push @{$result->{include_apps}}, keys %{$self->brand->whitelist_apps()};
    }

    return $result;
}

=head2 prefix_field

This returns a field by adding brand prefix.

This is required by myaffiliates.

myaffiliates system is not designed to have same login id across
different channels. They requested to add prefix to loginid for deriv
brand.

We may remove this in future once binary brand is removed.

=cut

sub prefix_field {
    my $self  = shift;
    my $field = shift;

    die "No data provided to be prefixed with brand" unless $field;

    my $brand_name = $self->brand->name // '';
    return "${brand_name}_${field}" if $brand_name eq 'deriv';

    return $field;
}

=head2 get_broker_code

Get broker code from the loginid

=cut

sub get_broker_code {
    my $self    = shift;
    my $loginid = shift;

    return '' unless $loginid;

    my ($broker_code) = $loginid =~ /^([A-Z]+)[0-9]+$/;

    return $broker_code // '';
}

=head2 is_broker_code_excluded

Check if broker code is in the excluded broker code list

=cut

sub is_broker_code_excluded {
    my ($self, $loginid) = @_;

    my $match = first { $_ eq $self->get_broker_code($loginid) } @{$self->exclude_broker_codes};

    return $match ? 1 : 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

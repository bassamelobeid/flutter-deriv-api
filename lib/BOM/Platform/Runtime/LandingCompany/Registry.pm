package BOM::Platform::Runtime::LandingCompany::Registry;
use strict;
use warnings;
use YAML::XS qw(LoadFile);

use BOM::Platform::Runtime::LandingCompany;

my (%landing_companies, @all_currencies, @all_landing_companies);

BEGIN {
    my $loaded_landing_companies = LoadFile('/home/git/regentmarkets/bom-platform/config/landing_companies.yml');
    my %currencies;
    while (my ($k, $v) = each %$loaded_landing_companies) {
        $v->{name} ||= $k;
        my $lc = BOM::Platform::Runtime::LandingCompany->new($v);
        $landing_companies{$k} = $lc;
        $landing_companies{$v->{short}} = $lc;
        push @all_landing_companies, $lc;
        @currencies{@{$v->{legal_allowed_currencies}}} = ();
    }
    @all_currencies = keys %currencies;
}

=head1 METHODS

=head2 new

=cut

sub new {
    my $class = shift;
    return bless {}, $class;
}

=head2 get

=cut

sub get {
    my $name = $_[-1];
    return $landing_companies{$name};
}

sub all_currencies {
    return @all_currencies;
}

sub all {
    return @all_landing_companies;
}

1;

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

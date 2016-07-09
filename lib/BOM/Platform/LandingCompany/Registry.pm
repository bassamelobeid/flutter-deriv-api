package BOM::Platform::LandingCompany::Registry;
use strict;
use warnings;
use YAML::XS qw(LoadFile);

use BOM::Platform::LandingCompany;

my (%landing_companies, %landing_company_by_broker, @all_currencies, @all_landing_companies, @all_broker_codes);

BEGIN {
    my $loaded_landing_companies = LoadFile('/home/git/regentmarkets/bom-platform/config/landing_companies.yml');
    my %currencies;
    while (my ($k, $v) = each %$loaded_landing_companies) {
        $v->{name} ||= $k;
        my $lc = BOM::Platform::LandingCompany->new($v);
        $landing_companies{$k} = $lc;
        $landing_companies{$v->{short}} = $lc;
        push @all_landing_companies, $lc;
        push @all_broker_codes,      @{$v->{broker_codes}};
        map { $landing_company_by_broker{$_} = $lc } @{$v->{broker_codes}};
        @currencies{@{$v->{legal_allowed_currencies}}} = ();
    }
    @all_currencies = keys %currencies;
}

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub get {
    my $name = shift;
    # if calls as object method
    if (ref $name) {
        $name = shift;
    }

    return $landing_companies{$name};
}

sub get_by_broker {
    my $broker = shift;

    if ($broker =~ /^([A-Z]+)\d+$/) {
        $broker = $1;
    }
    return $landing_company_by_broker{$broker};
}

sub all_currencies {
    return @all_currencies;
}

sub all_broker_codes {
    return @all_broker_codes;
}

sub all {
    return @all_landing_companies;
}

1;

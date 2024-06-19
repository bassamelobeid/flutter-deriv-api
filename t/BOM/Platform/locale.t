use strict;
use warnings;
use List::Util;
use Test::More;
use Test::Deep;
use BOM::Platform::Locale;
use BOM::Platform::Context qw(request localize);
use Locale::SubCountry;

subtest 'Netherlands' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('nl')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/SX AW BQ1 BQ2 BQ3 CW/;
};

subtest 'France' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('fr')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/BL WF PF PM/;
};

subtest 'Get state option: translate default subdivision' => sub {
    request(BOM::Platform::Context::Request->new(brand_name => 'deriv', language => 'de'));
    my @states = @{BOM::Platform::Locale::get_state_option('va')};
    ok scalar @states == 1,                  "Vatican seems to have multiple states";
    ok $states[0]->{text} eq 'Vatikanstadt', "did not get correct value for Vatican City";
    #do we need to reset the language for the rest of the tests?
    request(BOM::Platform::Context::Request->new(brand_name => 'deriv', language => 'en'));
};

subtest 'Valid state by value' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('BA', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash';

    cmp_deeply BOM::Platform::Locale::validate_state('ba', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash with lowercased state code';
};

subtest 'Valid state by text' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('Bali', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct state hash';

    cmp_deeply BOM::Platform::Locale::validate_state('bali', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash with lowercased state name';
};

subtest 'Invalid state' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('Bury', 'id'), undef, 'got undefined if state is invalid for a given country';
};

subtest 'Non-empty state list' => sub {
    my $countries_instance = request()->brand->countries_instance;
    my $countries          = $countries_instance->countries;
    my @stateless;

    for my $country (sort $countries->all_country_codes) {
        subtest "country: $country" => sub {
            my $list   = BOM::Platform::Locale::get_state_option($country);
            my $states = [grep { $_->{value} } @$list];
            ok scalar $states->@*, "state list not empty for $country";

            my $valid = List::Util::all { BOM::Platform::Locale::validate_state($_->{value}, $country) } $states->@*;
            ok $valid, 'all states are valid';

            my $country_obj = Locale::SubCountry->new($country);

            if ($country_obj and !$country_obj->has_sub_countries) {
                my $country_name = $countries->localized_code2country($country, request()->language);

                cmp_deeply $states,
                    [{
                        value => '00',
                        text  => $country_name,
                    }
                    ],
                    'Expected default state added';

                push @stateless, $country;
            }
        };
    }

    my @expected_stateless =
        qw/ai aq as aw ax bl bm bv cc ck cw cx eh fk fo gf gg gi gp gs gu hk hm im io je ky lc mf mo mp mq ms nc nf nu pf pm pn pr re sj sx tc tf tk va vg vi wf yt/;
    cmp_bag \@expected_stateless, \@stateless, 'Expected stateless country list';

    subtest 'invalid country must be undefined' => sub {
        is BOM::Platform::Locale::get_state_option('0x00'), undef, 'Not defined states list for 0x00';
    };
};

my %codes = Locale::SubCountry::World->code_full_name_hash;

sub old_get_state_option {
    my $country_code = shift or return;

    $country_code = uc $country_code;
    return unless $codes{$country_code};

    my @options = ();

    my $country = Locale::SubCountry->new($country_code);
    if ($country and $country->has_sub_countries) {
        my %name_map = $country->full_name_code_hash;
        push @options, map { {value => $name_map{$_}, text => $_} }
            sort $country->all_full_names;
    }

    # to avoid issues let's assume a stateless country has a default self-titled state

    if (scalar @options == 0) {
        my $countries_instance = request()->brand->countries_instance;
        my $countries          = $countries_instance->countries;
        my $country_name       = $countries->localized_code2country($country_code, request()->language);

        push @options,
            {
            value => '00',
            text  => $country_name,
            };
    }

    # Filter out some Netherlands territories
    @options = grep { $_->{value} !~ /\bSX|AW|BQ1|BQ2|BQ3|CW\b/ } @options if $country_code eq 'NL';
    # Filter out some France territories
    @options = grep { $_->{value} !~ /\bBL|WF|PF|PM\b/ } @options if $country_code eq 'FR';

    return \@options;
}

subtest 'Validate backwards compatibility' => sub {
    my $countries_instance = request()->brand->countries_instance;
    my $countries          = $countries_instance->countries;
    for my $country (sort $countries->all_country_codes) {
        subtest "country: $country" => sub {
            my $list     = BOM::Platform::Locale::get_state_option($country);
            my $old_list = old_get_state_option($country);
            cmp_deeply $list, $old_list, 'Should have the same result as the old get_state_option';
        }
    }
};

subtest 'Get state by id' => sub {
    cmp_deeply BOM::Platform::Locale::get_state_by_id('BA', 'id'), 'Bali', 'got correct state name';

    cmp_deeply BOM::Platform::Locale::get_state_by_id('ba', 'id'), undef, 'got undef with lowercased state code';
};

subtest 'translate salutation' => sub {
    cmp_deeply BOM::Platform::Locale::translate_salutation('Mr'), 'Mr', 'got correct salutation';
};

done_testing;

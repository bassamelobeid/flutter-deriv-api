test:
	/etc/rmg/bin/prove -lvr t/

pod_test:
	/etc/rmg/bin/prove -vlr t/*pod*.t


syntax:
	/etc/rmg/bin/prove --norc t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find bin lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/OAuth.pm > README.md

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test  t/BOM/
	cover -report coveralls

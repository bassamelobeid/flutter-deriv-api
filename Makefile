test:
	/etc/rmg/bin/prove -lvr t/

critique:
	/etc/rmg/bin/prove -l t/BOM/003_autosyntax.t

tidy:
	find . -name '*.p?.bak' -delete
	find scripts lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/API/Payment.pm > README.md

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test  t/plack
	cover -report coveralls

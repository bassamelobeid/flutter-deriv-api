test:
	/etc/rmg/bin/prove --exec '/etc/rmg/bin/perl -MTest::FailWarnings=-allow_deps,1 -Ilib/' -lr t/BOM/

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/OAuth.pm > README.md

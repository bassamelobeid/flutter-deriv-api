tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	/etc/rmg/bin/prove -lr --exec 'perl -Ilib -It/lib -MTest::FailWarnings=-allow_deps,1' t/

doc:
	pod2markdown lib/BOM/Test.pm > README.md

test_all:
	bin/test_all.sh

test:
	/etc/rmg/bin/prove -lr t/

critique:
	/etc/rmg/bin/prove -l t/BOM/003_autosyntax.t

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

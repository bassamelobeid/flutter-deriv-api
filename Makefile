# run perltidy on changed files only (relative to origin/master)
tidy:
	find . -name '*.p?.bak' -delete
	git diff --name-only origin/master | grep -E '(\.pm|\.t|\.pl)$$' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

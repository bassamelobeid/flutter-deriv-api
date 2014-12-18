CURRENT_BRANCH_SAFE=$(shell git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')

default:
	@echo "You must specify target. The following targets available:"
	@echo "  tidy         - Run perltidy"
	@echo "  critique     - Run perlcritic"

critique:
	prove -l t/BOM/003_autosyntax.t

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

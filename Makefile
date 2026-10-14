# Build and test beady.
#
#   make compile   byte-compile all files (warnings are errors)
#   make test      run the ERT test suite (integration tests need `bd')
#   make lint      run checkdoc and, if available, package-lint
#
# Extra load-path entries (e.g. for evil, markdown-mode or package-lint)
# can be passed with LOAD_PATH, for example:
#
#   make test LOAD_PATH="-L ~/.emacs.d/elpa/evil-1.15.0"

EMACS ?= emacs
LOAD_PATH ?=
BATCH = $(EMACS) -Q --batch -L . $(LOAD_PATH)

SRCS = beady-core.el beady-actions.el beady-show.el beady-list.el beady.el beady-evil.el
TESTS = test/beady-test.el

.PHONY: all compile test lint clean

all: compile test

compile: clean
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRCS)

test:
	$(BATCH) -L test -l $(TESTS) -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) --eval '(dolist (f (list $(patsubst %,"%",$(SRCS)))) (checkdoc-file f))'
	-$(BATCH) --eval "(require 'package-lint)" -f package-lint-batch-and-exit beady.el

clean:
	rm -f *.elc test/*.elc

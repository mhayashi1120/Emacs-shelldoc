EMACS = emacs

ELPA_ARGS = -f "package-initialize"

check: compile
	$(EMACS) -q -batch $(ELPA_ARGS) -L . -l shelldoc.el -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit
	$(EMACS) -q -batch $(ELPA_ARGS) -L . -l shelldoc.elc -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --version
	$(EMACS) -q -batch $(ELPA_ARGS) -L . -f batch-byte-compile shelldoc.el

EMACS = emacs

check: compile
	$(EMACS) -q -batch -L . -l shelldoc.el -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit
	$(EMACS) -q -batch -L . -l shelldoc.elc -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --version
	$(EMACS) -q -batch -L . -f batch-byte-compile shelldoc.el

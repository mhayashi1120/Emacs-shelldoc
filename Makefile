EMACS = emacs
ELPA_DIR = ~/.emacs.d/elpa/

check: compile
	$(EMACS) -q -batch -L . -L $(ELPA_DIR)/s-20*/ -l shelldoc.el -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit
	$(EMACS) -q -batch -L . -L $(ELPA_DIR)/s-20*/ -l shelldoc.elc -l shelldoc-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -q -batch -L $(ELPA_DIR)/s-20*/ -f batch-byte-compile shelldoc.el

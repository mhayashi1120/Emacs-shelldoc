shelldoc.el
============

Improve edit shell command in minibuffer.

Install
=======

Please install this package from MELPA. (http://melpa.milkbox.net/)

Otherwise put this file into load-path'ed directory.
And put the following expression into your ~/.emacs.
You may need some extra packages.

    (require 'shelldoc)

Usage
=====

Now you can see man page when `read-shell-command' is invoked.
C-v/M-v to scroll the man page window.
C-c C-s / C-c C-r to search the page.

* You can complete `-' (hyphen) option at point.
  Try to type C-i after insert `-' when showing shelldoc window.

* You may install new man page after shelldoc:

    M-x shelldoc-clear-cache

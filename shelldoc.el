;;; shelldoc.el --- Shell command editing support with man page.

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: applications
;; URL: http://github.com/mhayashi1120/Emacs-shelldoc/raw/master/shelldoc.el
;; Version: 0.0.1
;; Package-Requires: ((cl-lib "0.3") (s "1.9.0"))

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; * Install
;; Please install this package from MELPA. (http://melpa.milkbox.net/)
;;
;; Otherwise put this file into load-path'ed directory.
;; And put the following expression into your ~/.emacs.
;; You may need some extra packages.
;;
;;     (require 'shelldoc)

;; Now you can see man page when `read-shell-command' is invoked.
;; C-v/M-v to scroll the man page window.
;; C-c C-s / C-c C-r to search the page.

;; * You can complete `-` (hyphen) option at point.
;;   Try to type C-i after insert `-` when showing shelldoc window.

;; * You may install new man page after use shelldoc:
;;
;;     M-x shelldoc-clear-cache

;;; Code:

(require 'cl-lib)
(require 'man)
(require 's)
(require 'advice)
(require 'shell)

(defgroup shelldoc ()
  "shell command editing support with man page."
  :group 'applications
  :prefix "shelldoc-")

(put 'shelldoc-quit 'error-conditions '(shelldoc-quit error))
(put 'shelldoc-quit 'error-message "shelldoc error")

;;;
;;; Process
;;;

(defmacro shelldoc--man-environ (&rest form)
  `(with-temp-buffer
     (let ((process-environment (copy-sequence process-environment)))
       (setenv "LANG" "C")
       ;; unset unnecessary env variables
       (setenv "MANROFFSEQ")
       (setenv "MANSECT")
       (setenv "PAGER")
       (setenv "LC_MESSAGES")
       (progn ,@form))))

(defun shelldoc--call-man-to-string (args)
  (shelldoc--man-environ
   (when (= (apply
             'call-process
             manual-program
             nil t nil
             args) 0)
     (buffer-string))))

(defun shelldoc--read-manpage (name &optional section lang)
  (let ((args '()))
    (when lang
      (setq args (append args (list "-L" lang))))
    ;; restrict only two section
    ;; 1. Executable programs or shell commands
    ;; 8. System administration commands (usually only for root)
    (setq args (append
                (list (format "--sections=%s"
                              (or section "1,8")))
                args))
    (setq args (append args (list name)))
    (shelldoc--call-man-to-string args)))

(defun shelldoc--manpage-exists-p (name &optional section)
  (let* ((args (list
                (format "--sections=%s"
                        (or section "1,8"))
                "--where" name))
         (out (shelldoc--call-man-to-string args)))
    (and out (s-trim out))))

;;;
;;; Cache (process result)
;;;

;;TODO name/section/lang
(defvar shelldoc--man-cache
  (make-hash-table :test 'equal))

(defun shelldoc--get-manpage (cmd)
  (let ((name (shelldoc--convert-man-name cmd)))
    (or (gethash name shelldoc--man-cache)
        (let* ((page (shelldoc--read-manpage name))
               (man (if page (list name page) 'unavailable)))
          (puthash name man shelldoc--man-cache)
          man))))

(defun shelldoc--filter-manpage-args (args)
  (remq nil
        (mapcar
         (lambda (c)
           (when (shelldoc--maybe-command-name-p c)
             (let ((name (shelldoc--convert-man-name c)))
               (cond
                ((not (memq (gethash name shelldoc--man-cache)
                            '(nil unavailable)))
                 c)
                ((not (shelldoc--manpage-exists-p name))
                 (puthash name 'unavailable shelldoc--man-cache)
                 nil)
                (t c)))))
         args)))

;;;
;;; Parsing
;;;

;; Using `read' to implement easily.
(defun shelldoc--parse-current-command-line ()
  (save-excursion
    (let ((start (minibuffer-prompt-end)))
      (skip-chars-backward "\s\t\n" start)
      (let ((first (point))
            before after)
        (goto-char start)
        (ignore-errors
          ;; cursor is after command
          (while (< (point) first)
            (let ((segs (shelldoc--read-command-args)))
              (setq before (append before segs)))))
        (ignore-errors
          (while t
            (let ((segs (shelldoc--read-command-args)))
              (setq after (append after segs)))))
        (list before after)))))

(defun shelldoc--read-command-args ()
  (skip-chars-forward ";\s\t\n")
  (let* ((exp (read (current-buffer)))
         (text (format "%s" exp)))
    (cond
     ;; general (e.g. --prefix=/usr/local)
     ((string-match "\\`\\(-.+?\\)=\\(.+\\)" text)
      (list (match-string 1 text) (match-string 2 text)))
     (t
      (list text)))))

(defun shelldoc--maybe-command-name-p (text)
  (and
   ;; Detect environment
   (not (string-match "=" text))
   ;; Detect general optional arg
   (not (string-match "\\`-" text))))

(defun shelldoc--convert-man-name (command)
  (let ((nondir (file-name-nondirectory command))
        (re (concat "\\(.+?\\)" (regexp-opt exec-suffixes) "\\'")))
    (if (string-match re nondir)
        (match-string 1 nondir)
      nondir)))

;;;
;;; Text manipulation
;;;

(defun shelldoc--create-wordify-regexp (keyword)
  (let* ((base-re (concat "\\(" (regexp-quote keyword) "\\)"))
         ;; do not use "\\b" sequence
         ;; keyword may be "--option" like string which start with
         ;; non word (FIXME: otherwise define new syntax?)
         (non-word "[][\s\t\n:,=|]")
         (regexp (concat non-word base-re non-word)))
    regexp))

;;;
;;; argument to man page name
;;;

(defcustom shelldoc-arguments-to-man-filters
  '(shelldoc--git-commands-filter)
  "Functions each accept one arg which indicate string list and
 return physical man page name.
See the `shelldoc--git-commands-filter' as sample."
  :group 'shelldoc
  :type 'hook)

(defun shelldoc--git-commands-filter (args)
  (and (equal (car args) "git")
       (stringp (cadr args))
       (format "git-%s" (cadr args))))

(defun shelldoc--guess-manpage-name (args)
  (or
   (run-hook-with-args-until-success
    'shelldoc-arguments-to-man-filters
    args)
   (let* ((filtered (shelldoc--filter-manpage-args args))
          (last (last filtered)))
     (car last))))

;;;
;;; Completion
;;;

;;TODO improve regexp
;; OK: -a, --all
;; NG: --all, -a
(defconst shelldoc--man-option-re
  (eval-when-compile
    (mapconcat
     'identity
     '(
       ;; general option segment start
       "^\\(?:[\s\t]*\\(-[^\s\t\n,]+\\)\\)"
       ;; long option
       "\\(--[-_a-zA-Z0-9]+\\)"
       )
     "\\|")))

;; gather text by REGEXP first subexp of captured
(defun shelldoc--gather-regexp (regexp)
  (let ((buf (shelldoc--popup-buffer))
        (res '())
        (depth (regexp-opt-depth regexp)))
    (with-current-buffer buf
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (let ((text (cl-loop for i from 1 to depth
                             if (match-string-no-properties i)
                             return (match-string-no-properties i))))
          (unless (member text res)
            (setq res (cons text res)))))
      (nreverse res))))

;; Adopted `completion-at-point'
(defun shelldoc-option-completion ()
  (save-excursion
    (let ((end (point)))
      (skip-chars-backward "^\s\t\n")
      (when (looking-at "[\"']?\\(-\\)")
        ;;TODO show window
        ;; (shelldoc-print-info)
        (let ((start (match-beginning 1))
              (collection (shelldoc--gather-regexp
                           shelldoc--man-option-re)))
          (if collection
              (list start end collection nil)
            nil))))))

;;;
;;; UI
;;;

(defcustom shelldoc-idle-delay 0.3
  "Seconds to delay until popup man page."
  :group 'shelldoc
  :type 'number)

(defface shelldoc-short-help-face
  '((t :inherit match))
  "Face to highlight word in shelldoc."
  :group 'shelldoc)

(defface shelldoc-short-help-emphasis-face
  '((t :inherit match :bold t :underline t))
  "Face to highlight word in shelldoc."
  :group 'shelldoc)

(defvar shelldoc--current-man-name nil)
(defvar shelldoc--current-commands nil)

(defvar shelldoc--mode-line
  (eval-when-compile
    (concat
     "\\<shelldoc-minibuffer-map>"
     "\\[shelldoc-scroll-doc-window-up]:scroll-up"
     " "
     "\\[shelldoc-scroll-doc-window-down]:scroll-down"
     )))

;;
;; window/buffer manipulation
;;

(defvar shelldoc--saved-window-configuration nil)

(defun shelldoc--popup-buffer ()
  (let ((buf (get-buffer "*Shelldoc*")))
    (unless buf
      (setq buf (get-buffer-create "*Shelldoc*"))
      (with-current-buffer buf
        (kill-all-local-variables)
        (setq buffer-undo-list t)
        (setq mode-line-format
              `(,(substitute-command-keys
                  shelldoc--mode-line)
                ))))
    buf))

(defun shelldoc--windows-bigger-order ()
  (mapcar
   'car
   (sort
    (mapcar
     (lambda (w)
       (cons w (* (window-height w) (window-width w))))
     (window-list))
    (lambda (w1 w2) (> (cdr w1) (cdr w2))))))

(defun shelldoc--delete-window ()
  (let* ((buf (shelldoc--popup-buffer))
         (win (get-buffer-window buf)))
    (when win
      (delete-window win))))

(defun shelldoc--prepare-window ()
  (let* ((buf (shelldoc--popup-buffer))
         (all-wins (shelldoc--windows-bigger-order))
         (winlist (cl-remove-if-not
                   (lambda (w)
                     (eq (window-buffer w) buf)) all-wins)))
    ;; delete if multiple window is shown.
    ;; probablly no error but ignore error just in case.
    (ignore-errors
      (when (> (length winlist) 1)
        (dolist (w (cdr winlist))
          (delete-window w))))
    (or (car winlist)
        ;; split the biggest window
        (let* ((win (car all-wins))
               (newwin
                (condition-case nil
                    (split-window win)
                  (error
                   (signal 'shelldoc-quit nil)))))
          (set-window-buffer newwin buf)
          (select-window (minibuffer-window) t)
          newwin))))

(defun shelldoc--set-window-cursor (win words)
  (let* ((last (car (last words)))
         (regexps '()))
    (when last
      (when (string-match "\\`-" last)
        ;; general man page option start with spaces and hiphen
        (push (format "^[\s\t]+%s\\_>" (regexp-quote last)) regexps))
      (when (string-match "\\`--" last)
        ;; e.g. git add --force
        (push (format "^[\s\t]+-[^-][\s\t]*,[\s\t]*%s" (regexp-quote last))
              regexps))
      (when (string-match "\\`\\(-[^=]+\\)=" last)
        ;; e.g. print --action=
        (let ((last-arg (match-string 1 last)))
          (push (format "^[\s\t]+%s=" (regexp-quote last-arg)) regexps)))
      ;; default regexp if not matched to above
      (push (shelldoc--create-wordify-regexp last) regexps)
      (setq regexps (nreverse regexps))
      (with-current-buffer (shelldoc--popup-buffer)
        (goto-char (point-min))
        ;; goto first found (match strictly)
        (catch 'done
          (while regexps
            (when (let ((case-fold-search nil))
                    (re-search-forward (car regexps) nil t))
              ;; 5% margin
              (let ((margin (truncate (* (window-height win) 0.05))))
                (set-window-start win (point-at-bol (- margin)))
                nil)
              (throw 'done t))
            (setq regexps (cdr regexps)))
          ;; Keep window start
          )))))

;; FUNC must not change selected-window
(defun shelldoc--invoke-function (func)
  (let ((win (get-buffer-window (shelldoc--popup-buffer))))
    (when win
      (let ((prevwin (selected-window)))
        (unwind-protect
            (progn
              (select-window win)
              (funcall func))
          (select-window prevwin))))))

;;
;; drawing
;;

(defcustom shelldoc-fuzzy-match-requires 2
  "Number of character to highlight with fuzzy search."
  :group 'shelldoc
  :type 'integer)

(defun shelldoc--prepare-man-page (page)
  (with-current-buffer (shelldoc--popup-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert page))))

(defun shelldoc--prepare-buffer (words)
  (with-current-buffer (shelldoc--popup-buffer)
    (remove-overlays)

    (dolist (word words)
      (when (>= (length word) shelldoc-fuzzy-match-requires)
        (let ((regexp (concat "\\(" (regexp-quote word) "\\)")))
          ;; fuzzy search
          (shelldoc--mark-regexp regexp 'shelldoc-short-help-face t))))
    (let* ((last (car (last words)))
           (regexp (shelldoc--create-wordify-regexp last)))
      ;; strict search
      (shelldoc--mark-regexp regexp 'shelldoc-short-help-emphasis-face nil))
    ;; To initialize, goto min
    (goto-char (point-min))))

(defun shelldoc--mark-regexp (regexp face case-fold)
  (let ((case-fold-search case-fold))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (let* ((start (match-beginning 1))
             (end (match-end 1))
             (ov (make-overlay start end)))
        (overlay-put ov 'face face)))))

(defun shelldoc--clear-showing ()
  (setq shelldoc--current-man-name nil)
  (setq shelldoc--current-commands nil))

(defun shelldoc--print-command-info ()
  (cl-destructuring-bind (cmd-before cmd-after)
      (shelldoc--parse-current-command-line)
    (let ((cmd (shelldoc--guess-manpage-name cmd-before))
          (clear (lambda ()
                   (shelldoc--delete-window)
                   (shelldoc--clear-showing))))
      (cond
       ((null cmd)
        (funcall clear))
       (t
        (let ((man (shelldoc--get-manpage cmd)))
          (cond
           ((or (null man) (eq 'unavailable man))
            (funcall clear))
           (t
            (cl-destructuring-bind (name page) man
              (unless (equal name shelldoc--current-man-name)
                (shelldoc--prepare-man-page page)
                (setq shelldoc--current-man-name name)))

            (let ((changed (not (equal shelldoc--current-commands
                                       cmd-before))))
              (when changed
                (shelldoc--prepare-buffer cmd-before))
              ;; arrange window visibility.
              ;; may be deleted multiple buffer window.
              (let ((win (shelldoc--prepare-window)))
                ;; set `window-start' when change command line virtually
                (when changed
                  (shelldoc--set-window-cursor win cmd-before)))
              (setq shelldoc--current-commands cmd-before))))))))))

;;
;; Command
;;

(defun shelldoc-scroll-doc-window-up (&optional arg)
  (interactive "p")
  (let* ((buf (shelldoc--popup-buffer))
         (win (get-buffer-window buf))
         (minibuffer-scroll-window win)
         (base-lines (truncate (* (window-height win) 0.8)))
         (scroll-lines (* arg base-lines)))
    ;; ARG is lines of text
    (scroll-other-window scroll-lines)))

(defun shelldoc-scroll-doc-window-down (&optional arg)
  (interactive "p")
  (shelldoc-scroll-doc-window-up (- arg)))

;;TODO
(defun shelldoc-switch-popup-window ()
  "Not yet implemented"
  (interactive)
  (error "Not yet implemented"))

;;TODO
(defun shelldoc-switch-language ()
  "Not yet implemented"
  (interactive)
  (error "Not yet implemented"))

;;TODO
(defun shelldoc-isearch-forward-document ()
  "testing: Search text in document buffer."
  (interactive)
  (shelldoc--invoke-function 'isearch-forward))

;;TODO
(defun shelldoc-isearch-backward-document ()
  "testing: Search text in document buffer."
  (interactive)
  (shelldoc--invoke-function 'isearch-backward))

(defvar shelldoc-minibuffer-map nil)
(unless shelldoc-minibuffer-map
  (let ((map (make-sparse-keymap)))

    (set-keymap-parent map minibuffer-local-shell-command-map)
    (define-key map  "\C-v" 'shelldoc-scroll-doc-window-up)
    (define-key map  "\ev" 'shelldoc-scroll-doc-window-down)
    ;; (define-key map "\ec" 'shelldoc-switch-popup-window)
    ;; (define-key map "\ec" 'shelldoc-switch-language)
    (define-key map "\C-c\C-s" 'shelldoc-isearch-forward-document)
    (define-key map "\C-c\C-r" 'shelldoc-isearch-backward-document)

    (setq shelldoc-minibuffer-map map)))

(defvar shelldoc--original-minibuffer-map nil)

;; To suppress byte-compile warnings do not use `shelldoc' var name.
(defvar shelldoc:on nil)

(defun shelldoc (&optional arg)
  "Activate/Deactivate `shelldoc'."
  (interactive
   (list (and current-prefix-arg
              (prefix-numeric-value current-prefix-arg))))
  (cond
   ((or (and (numberp arg) (cl-minusp arg))
        (and (null arg) shelldoc:on))
    (ad-disable-advice
     'read-shell-command 'before
     'shelldoc-initialize-read-shell-command)
    (ad-update 'read-shell-command)
    ;; restore old map
    (setq minibuffer-local-shell-command-map
          shelldoc--original-minibuffer-map)
    ;; remove completion
    (setq shell-dynamic-complete-functions
          (remq 'shelldoc-option-completion
                shell-dynamic-complete-functions))
    (setq shelldoc:on nil))
   (t
    (ad-enable-advice
     'read-shell-command 'before
     'shelldoc-initialize-read-shell-command)
    (ad-activate 'read-shell-command)
    ;; save old map
    (setq shelldoc--original-minibuffer-map
          minibuffer-local-shell-command-map)
    ;; set new map
    (setq minibuffer-local-shell-command-map
          shelldoc-minibuffer-map)
    ;; for completion
    (add-to-list 'shell-dynamic-complete-functions
                 'shelldoc-option-completion)
    (shelldoc-clear-cache t)
    (setq shelldoc:on t)))
  (message "Now `shelldoc' is %s."
           (if shelldoc:on
               "activated"
             "deactivated")))

(defun shelldoc-clear-cache (&optional no-msg)
  "Clear cache to get newly installed file after shelldoc was activated."
  (interactive "P")
  (clrhash shelldoc--man-cache)
  (unless no-msg
    (message "shelldoc cache has been cleared.")))

;;;
;;; Load
;;;

;; shelldoc--setup:
;;  minibuffer-setup-hook <- shelldoc--initialize
;; shelldoc--initialize:
;;  minibuffer-setup-hook -> -> shelldoc--initialize
;;  minibuffer-exit-hook <- shelldoc--cleanup
;;
;; ***** shelldoc is working *****
;;
;; shelldoc--cleanup:
;;  minibuffer-exit-hook -> shelldoc--cleanup

(defvar shelldoc--minibuffer-depth nil)

(defun shelldoc-print-info ()
  (condition-case nil
      (cond
       ((minibufferp)
        (shelldoc--print-command-info)))
    (shelldoc-quit
     ;; terminate shelldoc
     ;; (e.g. too small window to split window)
     (shelldoc--cleanup))))

(defun shelldoc--initialize ()
  (when (= (minibuffer-depth) shelldoc--minibuffer-depth)
    ;; remove me
    (remove-hook 'minibuffer-setup-hook 'shelldoc--initialize)
    ;; add finalizer
    (add-hook 'minibuffer-exit-hook 'shelldoc--cleanup)
    ;; initialize internal vars
    (shelldoc--clear-showing)
    (setq shelldoc--saved-window-configuration
          (current-window-configuration))
    (run-with-idle-timer shelldoc-idle-delay t 'shelldoc-print-info)))

(defun shelldoc--cleanup ()
  ;; checking minibuffer-depth (e.g. helm conflict this)
  ;; lambda expression hard to `remove-hook' it
  (when (= (minibuffer-depth) shelldoc--minibuffer-depth)
    ;; remove me
    (remove-hook 'minibuffer-exit-hook 'shelldoc--cleanup)
    (cancel-function-timers 'shelldoc-print-info)
    (shelldoc--clear-showing)
    (set-window-configuration shelldoc--saved-window-configuration)
    (kill-buffer (shelldoc--popup-buffer))))

;;;###autoload
(defun shelldoc--setup ()
  (add-hook 'minibuffer-setup-hook 'shelldoc--initialize)
  (setq shelldoc--minibuffer-depth (1+ (minibuffer-depth))))

;; FIXME: switch to nadvice
;;;###autoload
(defadvice read-shell-command
    ;; default is `activate'
    (before shelldoc-initialize-read-shell-command () activate)
  (shelldoc--setup))

;; activate (after autoload / manually load)
(shelldoc 1)

;;;
;;; Unload
;;;

(defun shelldoc-unload-function ()
  (shelldoc -1)
  t)

(provide 'shelldoc)

;;; shelldoc.el ends here

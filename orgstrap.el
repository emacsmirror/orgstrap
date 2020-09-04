;;; orgstrap.el --- Bootstrap an org-mode file using file local variables -*- lexical-binding: t -*-

;; Author: Tom Gillespie
;; URL: https://github.com/tgbugs/orgstrap
;; Keywords: lisp org org-mode bootstrap
;; Version: 1.0
;; URL: https://github.com/purcell/flycheck-package
;; Package-Requires: ((emacs "24.4"))

;;;; License and Commentary

;; License:
;; GPLv3

;;; Commentary:

;; The license for the orgstrap.el code reflects the fact that
;; `orgstrap-get-block-checksum' reuses code from
;; `org-babel-check-confirm-evaluate' which is
;; (at the time of writing) in ob-core.el and licensed
;; as part of Emacs.

;; Code in an orgstrap block is usually meant to be executed directly by its
;; containing org file.  However, if the code is something that will be reused
;; over time outside the defining org file then it may be better to tangle and
;; load the file so that it is easier to debug/xref functions.  This code in
;; particular is tangled for inclusion in one of the *elpas so as to protect
;; the orgstrap namespace.

;;; Code:

;;; edit helpers
(defvar orgstrap-orgstrap-block-name "orgstrap"
  "Set the default blockname to orgstrap by convention.
This makes it easier to search for orgstrap if someone encounters
an orgstrapped file and wants to know what is going on.")

(defvar orgstrap-default-cypher 'sha256
  "The default cypher passed to `secure-hash' when hashing blocks.")

(defcustom orgstrap-on-change-hook nil
  "Hook run via `before-save-hook' when command `orgstrap-mode' is enabled.
Only runs when the contents of the orgstrap block have changed."
  :type 'hook
  :group 'orgstrap)

;; edit utility functions
(defun orgstrap--current-buffer-cypher ()
  "Return the cypher used for the current buffer.
The value returned is `orgstrap-cypher' or if there is not buffer local cypher
then `orgstrap-default-cypher' is returned."
  (if (boundp 'orgstrap-cypher) orgstrap-cypher orgstrap-default-cypher))

(when (not (fboundp 'org-src-coderef-regexp))
  (defun org-src-coderef-regexp (fmt &optional label)
    (let ((fmt org-coderef-label-format))
      (format "\\([:blank:]*\\(%s\\)[:blank:]*\\)$"
              (replace-regexp-in-string
               "%s"
               (if label
                   (regexp-quote label)
                 "\\([-a-zA-Z0-9_][-a-zA-Z0-9_ ]*\\)")
               (regexp-quote fmt)
               nil t)))))

(defun orgstrap--expand-body (info)
  "Expand references in INFO body if :noweb header is set."
  (let ((coderef (nth 6 info))
        (expand
         (if (org-babel-noweb-p (nth 2 info) :eval)
             (org-babel-expand-noweb-references info)
           (nth 1 info))))
    (if (not coderef)
        expand
      (replace-regexp-in-string
       (org-src-coderef-regexp coderef) "" expand nil nil 1))))

(defmacro orgstrap--with-block (blockname &rest macro-body)
  "Go to the source block named BLOCKNAME and execute MACRO-BODY.
The macro provides local bindings for four names:
`info', `params', `body-unexpanded', and `body'."
  (declare (indent defun))
  ;; consider accepting :lite or a keyword or something to pass
  ;; lite as an optional argument to `org-babel-get-src-block-info'
  ;; e.g. via (lite (equal (car macro-body) :lite)), given the
  ;; behavior when lite is not nil and the expected useage of this
  ;; macro I don't think we would ever want to pass a non nil lite
  `(save-excursion
     (let ((inhibit-message t)) ; inhibit-message only blocks from the message area not the log
       (org-babel-goto-named-src-block ,blockname))
     (unwind-protect
         (let* ((info (org-babel-get-src-block-info))
                (params (nth 2 info))
                (body-unexpanded (nth 1 info))
                ;; from `org-babel-check-confirm-evaluate'
                ;; and `org-babel-execute-src-block'
                (body (orgstrap--expand-body info)))
           ,@macro-body)
       (org-mark-ring-goto))))

;; edit user facing functions
(defun orgstrap-get-block-checksum (&optional cypher)
  "Calculate the `orgstrap-block-checksum' for the current buffer using CYPHER."
  (interactive)
  (orgstrap--with-block orgstrap-orgstrap-block-name
    (ignore params body-unexpanded)
    (let ((cypher (or cypher (orgstrap--current-buffer-cypher)))
          (body-normalized
           (let ((print-quoted nil))
             (prin1-to-string (read (concat "(progn\n" body "\n)"))))))
      (secure-hash cypher body-normalized))))

(defun orgstrap-add-block-checksum (&optional cypher checksum)
  "Add `orgstrap-block-checksum' to file local variables of `current-buffer'.
The optional CYPHER argument should almost never be used,
instead change the value of `orgstrap-default-cypher' or manually
change the file property line variable.  CHECKSUM can be passed
directly if it has been calculated before and only needs to be set."
  (interactive)
  (let* ((cypher (or cypher (orgstrap--current-buffer-cypher)))
         (orgstrap-block-checksum (or checksum (orgstrap-get-block-checksum cypher))))
    (when orgstrap-block-checksum
      (save-excursion
        (add-file-local-variable-prop-line 'orgstrap-cypher cypher)
        (add-file-local-variable-prop-line 'orgstrap-block-checksum (intern orgstrap-block-checksum))))
    orgstrap-block-checksum))

(defun orgstrap--update-on-change ()
  "Run via the `before-save-hook' local variable.
Test if the checksum of the orgstrap block has changed,
if so update the `orgstrap-block-checksum' local variable
and then run `orgstrap-on-change-hook'."
  (let* ((elv (orgstrap--read-current-local-variables))
         (cpair (assoc 'orgstrap-block-checksum elv))
         (checksum-existing (if cpair (cdr cpair) nil))
         (checksum (orgstrap-get-block-checksum)))
    (unless (eq checksum-existing (intern checksum))
      (remove-hook 'before-save-hook #'orgstrap--update-on-change t)
      ;; have to remove the hook because for some reason tangling from a buffer
      ;; counts as saving from that buffer?
      (save-excursion
        ;; using save-excusion here is a good for insurance against wierd hook issues
        ;; however it does not deal with the fact that updating `orgstrap-add-block-checksum'
        ;; adds an entry to the undo ring, which is bad
        ;;(undo-boundary)  ; undo-boundary doesn't quite work the way we want
        ;; related https://emacs.stackexchange.com/q/7558
        (orgstrap-add-block-checksum nil checksum)
        (run-hooks 'orgstrap-on-change-hook))
      (add-hook 'before-save-hook #'orgstrap--update-on-change 0 t))))

;;;###autoload
(define-minor-mode orgstrap-mode
  "Minor mode for working with orgstrapped files."
  nil "" nil

  (unless (eq major-mode 'org-mode)
    (setq orgstrap-mode nil)
    (user-error "`orgstrap-mode' only works with org-mode buffers"))

  (cond (orgstrap-mode
         (add-hook 'before-save-hook #'orgstrap--update-on-change 0 t))
        (t
         (remove-hook 'before-save-hook #'orgstrap--update-on-change))))

;;; init helpers
(require 'cl-lib)

(defvar orgstrap-link-message "jump to the orgstrap block for this file"
  "Default message for file internal links.")

(defconst orgstrap--default-local-variables-block-version "0.1"
  "End of file local variables verion number.
Used to set visible version number in the
file local variables in `orgstrap--add-file-local-variables'")

(defconst orgstrap--local-variable-eval-commands-0.1
  '(
    (when (not (fboundp 'org-src-coderef-regexp))
      (defun org-src-coderef-regexp (fmt &optional label)
        (let ((fmt org-coderef-label-format))
          (format "\\([:blank:]*\\(%s\\)[:blank:]*\\)$"
                  (replace-regexp-in-string
                   "%s"
                   (if label
                       (regexp-quote label)
                     "\\([-a-zA-Z0-9_][-a-zA-Z0-9_ ]*\\)")
                   (regexp-quote fmt)
                   nil t)))))
    
    (defun orgstrap--expand-body (info)
      "Expand references in INFO body if :noweb header is set."
      (let ((coderef (nth 6 info))
            (expand
             (if (org-babel-noweb-p (nth 2 info) :eval)
                 (org-babel-expand-noweb-references info)
               (nth 1 info))))
        (if (not coderef)
            expand
          (replace-regexp-in-string
           (org-src-coderef-regexp coderef) "" expand nil nil 1))))
    
    (defun orgstrap--confirm-eval (lang body)
      ;; `org-confirm-babel-evaluate' will prompt the user when the value
      ;; that is returned is non-nil, therefore we negate positive matchs
      (not (and (member lang '("elisp" "emacs-lisp"))
                (let* ((body (orgstrap--expand-body (org-babel-get-src-block-info)))
                       (body-normalized
                        (let ((print-quoted nil))
                          (prin1-to-string (read (concat "(progn\n" body "\n)")))))
                       (content-checksum
                        (intern
                         (secure-hash
                          orgstrap-cypher
                          body-normalized))))
                  ;;(message "%s %s" orgstrap-block-checksum content-checksum)
                  ;;(message "%s" body-normalized)
                  (eq orgstrap-block-checksum content-checksum)))))
    
    (setq-local org-confirm-babel-evaluate #'orgstrap--confirm-eval)
    
    (unwind-protect
        (save-excursion
          (org-babel-goto-named-src-block "orgstrap")
          (org-babel-execute-src-block))
      (setq-local org-confirm-babel-evaluate t)
      (fmakunbound #'orgstrap--confirm-eval))))

(defconst orgstrap--local-variable-eval-commands-0.2
  '(
    (defun orgstrap--confirm-eval (lang body)
      (not (and (member lang '("elisp" "emacs-lisp"))
                (eq orgstrap-block-checksum
                    (intern
                     (secure-hash
                      orgstrap-cypher
                      (let ((print-quoted nil))
                        (prin1-to-string (read (concat "(progn\n" body "\n)"))))))))))
    
    (setq-local org-confirm-babel-evaluate #'orgstrap--confirm-eval)
    
    (unwind-protect
        (save-excursion
          (org-babel-goto-named-src-block "orgstrap")
          (org-babel-execute-src-block))
      (setq-local org-confirm-babel-evaluate t)
      (fmakunbound #'orgstrap--confirm-eval))))

(defun orgstrap--local-variable-eval-commands (&optional version)
  "Return the set of eval local variable commands for VERSION."
  (let ((version (or version orgstrap--default-local-variables-block-version)))
    (pcase version
      ("0.1" orgstrap--local-variable-eval-commands-0.1)
      ("0.2" orgstrap--local-variable-eval-commands-0.2))))

;; init utility functions

(defun orgstrap--new-heading-elisp-block (heading block-name &optional header-args noexport)
  "Create a new elisp block named BLOCK-NAME in a new heading titled HEADING.
The heading is inserted at the top of the current file.
HEADER-ARGS is an alist of symbols that are converted to strings.
If NOEXPORT is non-nil then the :noexport: tag is added to the heading."
  (save-excursion
    (goto-char (point-min))
    (outline-next-heading)  ;; alternately outline-next-heading
    (org-meta-return)
    (insert (format "%s%s\n" heading (if noexport " :noexport:" "")))
    ;;(org-edit-headline heading)
    ;;(when noexport (org-set-tags "noexport"))
    (move-end-of-line 1)
    (insert "\n#+name: " block-name "\n")
    (insert "#+begin_src elisp")
    (mapc (lambda (header-arg-value)
            (insert " :" (symbol-name (car header-arg-value))
                    " " (symbol-name (cdr header-arg-value))))
          header-args)
    (insert "\n#+end_src\n")))

(defun orgstrap--trap-hack-locals (command &rest args)
  "Advice for `hack-local-variables-filter' to do nothing except the following.
Set `orgstrap--local-variables' to the reversed list of read variables which
are the first argument in the lambda list ARGS.
COMMAND is unused since we don't actually want to hack the local variables,
just get their current values."
  (ignore command)
  (setq-local orgstrap--local-variables (reverse (car args)))
  nil)

(defun orgstrap--read-current-local-variables ()
  "Return the local variables for the current file without applying them."
  (interactive)
  ;; orgstrap--local-variables is a temporary local variable that is used to
  ;; capture the input to `hack-local-variables-filter' it is unset at the end
  ;; of this function so that it cannot accidentally be used when it might be stale
  (setq-local orgstrap--local-variables nil)
  (let ((enable-local-variables t))
    (advice-add #'hack-local-variables-filter :around #'orgstrap--trap-hack-locals)
    (unwind-protect
        (hack-local-variables nil)
      (advice-remove #'hack-local-variables-filter #'orgstrap--trap-hack-locals))
    (let ((local-variables orgstrap--local-variables))
      (makunbound 'orgstrap--local-variables)
      local-variables)))

(defun orgstrap--add-link-to-orgstrap-block (&optional link-message)
  "Add an `org-mode' link pointing to the orgstrap block for the current file.
The link is placed in comment on the second line of the file.  LINK-MESSAGE
can be used to override the default value set via `orgstrap-link-message'"
  (interactive)  ; TODO prompt for message with C-u ?
  (goto-char (point-min))
  (next-logical-line)  ; use logical-line to avoid issues with visual line mode
  (let ((link-message (or link-message orgstrap-link-message)))
    (unless (save-excursion (re-search-forward
                             (format "^# \\[\\[%s\\]\\[.+\\]\\]$"
                                     orgstrap-orgstrap-block-name)
                             nil t))
      (insert (format "# [[%s][%s]]\n"
                      orgstrap-orgstrap-block-name
                      (or link-message orgstrap-link-message))))))

(defun orgstrap--add-orgstrap-block ()
  "Add a new elisp source block with #+name: orgstrap to the current buffer.
If a block with that name already exists raise an error."
  (interactive)
  (let ((all-block-names (org-babel-src-block-names)))
    (if (member orgstrap-orgstrap-block-name all-block-names)
        (message "orgstrap block already exists not adding!")
      (orgstrap--new-heading-elisp-block "Bootstrap"
                                         orgstrap-orgstrap-block-name
                                         '((results . none)
                                           (lexical . yes))
                                         t)
      (orgstrap--with-block orgstrap-orgstrap-block-name
        (ignore params body-unexpanded body)
        ;;(error "TODO insert some minimal message or something")
        nil))))

(defun orgstrap--add-file-local-variables (&optional version)
  "Add the file local variables needed to make orgstrap work.
VERSION is currently used to control whether 0.1 or 0.2 is used.
Version should be orthognal to whether the block supports noweb
and old versions of `org-mode' and the selection for noweb should
be detected automatically, similarly we could automatically include
a version test and fail if the version is unsupported."
  ;; switching comments probably wont work ? we can try
  ;; Use a prefix argument (i.e. C-u) to add file local variables comments instead of in a :noexport:
  (interactive)
  (let* ((version (or version orgstrap--default-local-variables-block-version))
         (lv-commands (orgstrap--local-variable-eval-commands version))
         (elv (orgstrap--read-current-local-variables))
         (commands-existing (mapcar #'cdr (cl-remove-if-not (lambda (l) (eq (car l) 'eval)) elv)))) ;(ref:clrin)
    ;; good enough to start
    (cond ((equal commands-existing lv-commands) nil)
          ((not commands-existing)
           (let ((print-escape-newlines t))  ; needed to preserve the escaped newlines
             (add-file-local-variable 'orgstrap-local-variables-block-version
                                      version)
             (mapcar (lambda (sexp) (add-file-local-variable 'eval sexp))
                     lv-commands)))
          ;; we could try to do something fancy here, but it is much simpler
          ;; to just alert the user and have them fix it
          (t (error "Existing eval commands that do not match the commands to be installed have been detected.  Please remove those commands and run `orgsrap-add-file-local-variables' again or manually add the orgstrap file local variables.  The existing commands are as follows.\n%s" commands-existing)))))

;; init user facing functions
;;;###autoload
(defun orgstrap-init ()
  "Initialize orgstrap in the current buffer and enable command `orgstrap-mode'."
  (interactive)
  (when (not (eq major-mode 'org-mode))
    (error "Cannot orgstrap, buffer not in `org-mode' it is in %s!" major-mode))
  ;; TODO option for no link?
  ;; TODO option for local variables in comments vs noexport
  (save-excursion
    (orgstrap--add-orgstrap-block)
    (orgstrap-add-block-checksum)
    (orgstrap--add-link-to-orgstrap-block)
    ;; FIXME sometimes local variables don't populate due to an out of range error
    (orgstrap--add-file-local-variables)
    (orgstrap-mode)))

;; install helpers
(defvar orgstrap-helper-block-name "orgstrap-helper"
  "Name for the embedded helper block.")
(defun orgstrap-install-orgstrap ()
  "Install orgstrap.el directly from this file."
  (error "TODO"))
(defun orgstrap--add-install-block ()
  "Install this block in an `org-mode' file." ; really? or was this meant to do something else?
  (error "TODO"))
(defun orgstrap--add-helper-block (&optional block-name)
  "Embed orgstrap helpers block named BLOCK-NAME in the current buffer.
This makes it so that anyone encountering the file in the future has all
the tools they need to make changes without requiring any additional steps."
  ;; TODO minimal vs maximal, edit files vs propagate orgstrap
  ;; go to start of file
  ;; look for first heading
  ;; insert before first heading (so it is visible and users can reorder as needed)
  ;; insert source block
  (let ((block-name (or block-name orgstrap-helper-block-name)))

    (orgstrap--new-heading-elisp-block "orgstrap-helpers"
                                       block-name
                                       '((results . none)
                                         (lexical . yes))
                                       t)

    (orgstrap--with-block block-name
      (ignore params body-unexpanded body)
      (error "TODO"))))

;;(defvar orgstrap--helpers nil)
;;(setq orgstrap--helpers nil)
;;; TODO
;; options are link to docs or
;; embed (defun orgstrap-install-helpers () (interactive) (use-package orgstrap)) or similar or
;; embed all of this block or orgstrap.el in a block in * orgstrap helpers :noexport:

;;; extra helpers
(defun orgstrap-update-src-block (name content)
  "Set the content of source block named NAME to string CONTENT.
XXX NOTE THAT THIS CANNOT BE USED WITH EXAMPLE BLOCKS."
  ;; FIXME this seems to fail if the existing block is empty?
  ;; or at least adding file local variables fails?
  (let ((block (org-babel-find-named-block name)))
    (if block
        (save-excursion
          (org-babel-goto-named-src-block name)
          (org-babel-update-block-body content))
      (error "No block with name %s" name))))

(defun orgstrap-get-src-block-checksum (&optional cypher)
  "Calculate of the checksum of the current source block using CYPHER."
  (interactive)
  (let* ((info (org-babel-get-src-block-info))
         (params (nth 2 info))
         (body-unexpanded (nth 1 info))
         (body (orgstrap--expand-body info))
         (body-normalized
          (let ((print-quoted nil))
            (prin1-to-string (read (concat "(progn\n" body "\n)")))))
         (cypher (or cypher (orgstrap--current-buffer-cypher))))
    (ignore params body-unexpanded)
    (secure-hash cypher body-normalized)))

(defun orgstrap-get-named-src-block-checksum (name &optional cypher)
  "Calculate the checksum of the first sourc block named NAME using CYPHER."
  (interactive)
  (orgstrap--with-block name
    (ignore params body-unexpanded)
    (let ((cypher (or cypher (orgstrap--current-buffer-cypher)))
          (body-normalized
           (let ((print-quoted nil))
             (prin1-to-string (read (concat "(progn\n" body "\n)"))))))
      (secure-hash cypher body-normalized))))

(defun orgstrap-run-additional-blocks (&rest name-checksum) ;(ref:oab)
  "Securely run additional blocks in languages other than elisp.
Do this by providing the name of the block and the checksum to be embedded
in the orgstrap block as NAME-CHECKSUM pairs."
  (ignore name-checksum)
  (error "TODO"))

(provide 'orgstrap)

;;; orgstrap.el ends here
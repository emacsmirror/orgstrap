;;; ow-min.el --- Minimal utilties for orgstrap blocks. -*- lexical-binding: t -*-

;; Author: Tom Gillespie
;; Homepage: https://github.com/tgbugs/orgstrap
;; Version: 9999
;; Package-Requires: ((emacs "24.4"))
;; Is-Version-Of: https://raw.githubusercontent.com/tgbugs/orgstrap/master/ow-min.el
;; Reval-Get-Immutable: ow-min--reval-update

;;;; License and Commentary

;; License:
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ow-min.el contains functionality needed by orgstrap blocks that are
;; primarily used by developers, such as files that implement a
;; release process where no end user interaction is expected.

;; ow-min.el is compatible with `reval-update'.

;;; Code:

(defvar-local defl--local-defuns nil
  "A hash table that maps global closures to local function symbols.
Needed to dispatch on command passed to :around advice.")

(defvar-local defl--local-defun-names nil
  "A hash table that maps global function symbols to local function symbols.")

(defun defl--has-local-defuns (command &rest args)
  "Advise COMMAND with ARGS to check if there are buffer local defuns."
  (let ((command (or (and defl--local-defuns
                          (gethash command defl--local-defuns))
                     command)))
    (apply command args)))

(defmacro defl (name arglist &optional docstring &rest body)
  "Define a buffer local function.
ARGLIST, DOCSTRING, and BODY are passed unmodified to `defun'

WARNING: If you redefine NAME with `defun' after using `defun-local'
then the current implementation will break."
  (declare (doc-string 3) (indent 2))
  (unless defl--local-defuns
    (setq-local defl--local-defuns (make-hash-table :test #'equal)))
  (unless defl--local-defun-names
    (setq-local defl--local-defun-names (make-hash-table)))
  (let ((docstring (if docstring (list docstring) docstring))
        (local-name (or (gethash name defl--local-defun-names)
                        (puthash name (cl-gentemp (format "%S-" name)) defl--local-defun-names))))
    `(prog1
         (defun ,local-name ,arglist ,@docstring ,@body)
       (unless (fboundp ',name)
         (defun ,name (&rest args) (error "global stub for defun-local %s" #',name))
         (put ',name 'defun-local-stub t))
       (puthash (symbol-function #',name) #',local-name defl--local-defuns) ; XXX broken if the stub is overwritten
       (advice-add #',name :around #'defl--has-local-defuns))))

(defalias 'defun-local #'defl)

(defun ow-run-command (command &rest args)
  "Run COMMAND with ARGS. Raise an error if the return code is not zero."
  ;; I'm being a good namespace citizen and prefixing this with ow- but
  ;; 99% of the time I'm going to have (defalias 'run-command #'ow-run-command)
  ;; in my orgstrap blocks that reval ow.el (since ow-min.el has it already)
  ;;(message "%S" (mapconcat #'identity (cons command args) " "))
  (with-temp-buffer
    (let* ((return-code (apply #'call-process command nil (current-buffer) nil args))
           (string (buffer-string)))
      (if (not (= 0 return-code))
          (error "code: %s stdout: %S" return-code string)
        string))))

(defalias 'run-command #'ow-run-command)

(defvar securl-default-cypher 'sha256)  ; remember kids, always publish the cypher with the checksum

(defun securl-path-checksum (path &optional cypher)
  "not as fast as using sha256sum, but requires no dependencies
1.4s vs .25s for ~60mb"
  (let ((cypher (or cypher securl-default-cypher)))
    (with-temp-buffer
      (insert-file-contents-literally path)
      (secure-hash cypher (current-buffer)))))

(defun securl (cypher checksum url path)
  "Securely fetch URL to PATH only if it matches CHECKSUM under CYPHER.
Files that do not match the checksum are quarantined."
  ;; unless the file exists or the checksum matches fetch and check
  (unless (and (file-exists-p path)
               (let ((existing-checksum (securl-path-checksum path cypher)))
                 (or (string= checksum existing-checksum)
                     ;; (not (message "checksum mismatch:\n%S\n%S" checksum existing-checksum))
                     (not (rename-file path
                                       (make-temp-file (concat path "._existing_failure_."))
                                       t)))))
    (let ((path-temp (make-temp-file (concat path "._fetching_."))))
      (url-copy-file url path-temp t)
      (let ((new-checksum (securl-path-checksum path-temp cypher)))
        (if (string= checksum new-checksum)
            (rename-file path-temp path)
          (let ((path-failure (make-temp-file (concat path "._checksum_failure_."))))
            (rename-file path-temp path-failure t)
            (error "checksum FAILED for path! %s" path-failure))))))
  ;; return nil in all cases the calling scope has the path and
  ;; whatever is at that path must have passed the current checksum
  nil)

(defun ow-url-head-ok (url)
  "Check if URL is up and OK using HTTP HEAD.
All errors are silenced."
  (let ((url-request-method "HEAD"))
    (condition-case nil
        (with-current-buffer (url-retrieve-synchronously url)
          ;;(buffer-substring (point-min) url-http-end-of-headers)
          (goto-char 0)
          (re-search-forward "^HTTP.+OK$"))
      (error nil))))

(defun ow-min--reval-update ()
  "Get the immutable url for the current remote version of this file."
  (reval-get-imm-github "tgbugs" "orgstrap" "ow-min.el"))

(provide 'ow-min)

;;; ow-min.el ends here

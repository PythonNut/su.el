;;; su.el --- Automatically read and write files as users -*- lexical-binding: t -*-

;; Copyright (C) 2018 PythonNut

;; Author: PythonNut <pythonnut@pythonnut.com>
;; Keywords: convenience, helm, fuzzy, flx
;; Version: 20151013
;; URL: https://github.com/PythonNut/helm-flx
;; Package-Requires: ((emacs "26.1"))

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package implements intelligent helm fuzzy sorting, provided by flx.

;; You can install the package by either cloning it yourself, or by doing M-x package-install RET helm-flx RET.

;; After that, you can enable it by putting the following in your init file:

;;     (helm-flx-mode +1)

;; See the README for more info.

;;; Code:
(eval-when-compile
  (with-demoted-errors "Byte-compile: %s"
    (require 'tramp)
    (require 'nadvice)))

(defgroup su nil
  "Automatically read and write files as users"
  :group 'convenience
  :prefix "su-")

(defcustom su-auto-make-directory t
  "Automatically become other users to create directories"
  :type 'boolean
  :group 'su)

(defcustom su-auto-write-file t
  "Automatically become other users to write files"
  :type 'boolean
  :group 'su)

(defcustom su-auto-read-file t
  "Automatically become other users to read files"
  :type 'boolean
  :group 'su)

(defcustom su-enable-helm-integration t
  "Enable integration with helm"
  :type 'boolean
  :group 'su)

(defcustom su-enable-semantic-integration t
  "Enable integration with semantic"
  :type 'boolean
  :group 'su)

(defcustom su-auto-save-mode-lighter
  (list " " (propertize "root" 'face 'tty-menu-selected-face))
  "The mode line lighter for su-auto-save-mode."
  :type 'list
  :group 'su)

;; Required for the face to be displayed
(put 'su-auto-save-mode-lighter 'risky-local-variable t)

(defun su--root-file-name-p (file-name)
  (and (featurep 'tramp)
       (tramp-tramp-file-p file-name)
       (with-parsed-tramp-file-name file-name parsed
         (when parsed-user
           (string= "root" (substring-no-properties parsed-user))))))

(defun su--get-current-user (file-name)
  (if (and (featurep 'tramp)
       (tramp-tramp-file-p file-name))
      (with-parsed-tramp-file-name file-name parsed
         (if parsed-user
             (substring-no-properties parsed-user)
           user-login-name))
    user-login-name))

(defun su--tramp-get-method-parameter (method param)
  (assoc param (assoc method tramp-methods)))

(defun su--tramp-corresponding-inline-method (method)
  (let* ((login-program
          (su--tramp-get-method-parameter method 'tramp-login-program))
         (login-args
          (su--tramp-get-method-parameter method 'tramp-login-args))
         (copy-program
          (su--tramp-get-method-parameter method 'tramp-copy-program)))
    (or
     ;; If the method is already inline, it's already okay
     (and login-program
          (not copy-program)
          method)

     ;; If the method isn't inline, try calculating the corresponding
     ;; inline method, by matching other properties.
     (and copy-program
          (cl-some
           (lambda (test-method)
             (when (and
                    (equal login-args
                           (su--tramp-get-method-parameter
                            test-method
                            'tramp-login-args))
                    (equal login-program
                           (su--tramp-get-method-parameter
                            test-method
                            'tramp-login-program))
                    (not (su--tramp-get-method-parameter
                          test-method
                          'tramp-copy-program)))
               test-method))
           (mapcar #'car tramp-methods)))

     ;; These methods are weird and need to be handled specially
     (and (member method '("sftp" "fcp"))
          "sshx"))))

(defun su--check-passwordless-sudo (&optional user)
  (let (process-file-side-effects)
    (= (apply #'process-file
              "sudo"
              nil
              nil
              nil
              "-n"
              "true"
              (when user
                (list "-u" user)))
       0)))

(defun su--check-password-sudo (&optional user)
  (let ((prompt "emacs-su-prompt")
        process-file-side-effects)
    (string-match-p
     prompt
     (with-output-to-string
       (with-current-buffer standard-output
         (apply #'process-file
                "sudo"
                nil
                t
                nil
                "-vSp"
                prompt
                (when user
                  (list "-u" user))))))))

(defun su--check-sudo (&optional user)
  (or (su--check-passwordless-sudo user)
      (su--check-password-sudo user)))

(defun su--make-root-file-name (file-name &optional user)
  (require 'tramp)
  (let* ((target-user (or user "root"))
         (abs-file-name (expand-file-name file-name))
         (sudo (with-demoted-errors "sudo check failed: %s"
                 (let ((default-directory
                         (my/file-name-first-existing-parent abs-file-name)))
                   (su--check-sudo user))))
         (su-method (if sudo "sudo" "su")))
    (if (tramp-tramp-file-p abs-file-name)
        (with-parsed-tramp-file-name abs-file-name parsed
          (if (string= parsed-user target-user)
              abs-file-name
            (tramp-make-tramp-file-name
             su-method
             target-user
             nil
             parsed-host
             nil
             parsed-localname
             (let ((tramp-postfix-host-format tramp-postfix-hop-format)
                   (tramp-prefix-format))
               (tramp-make-tramp-file-name
                (su--tramp-corresponding-inline-method parsed-method)
                parsed-user
                parsed-domain
                parsed-host
                parsed-port
                ""
                parsed-hop)))))
      (if (string= (user-login-name) user)
          abs-file-name
        (tramp-make-tramp-file-name su-method
                                    target-user
                                    nil
                                    "localhost"
                                    nil
                                    abs-file-name)))))

(defun su--nadvice-find-file-noselect-1 (old-fun buf filename &rest args)
  (condition-case err
      (apply old-fun buf filename args)
    (file-error
     (if (and (not (su--root-file-name-p filename))
              (y-or-n-p "File is not readable. Open with root? "))
         (let ((filename (su--make-root-file-name (file-truename filename))))
           (apply #'find-file-noselect-1
                  (or (get-file-buffer filename)
                      (create-file-buffer filename))
                  filename
                  args))
       (signal (car err) (cdr err))))))

(defun su--nadvice-make-directory-auto-root (old-fun &rest args)
  (cl-letf*
      ((old-md (symbol-function #'make-directory))
       ((symbol-function #'make-directory)
        (lambda (dir &optional parents)
          (if (and (not (su--root-file-name-p dir))
                   (not (file-writable-p
                         (my/file-name-first-existing-parent dir)))
                   (y-or-n-p "Insufficient permissions. Create with root? "))
              (funcall old-md
                       (su--make-root-file-name dir)
                       parents)
            (funcall old-md dir parents)))))
    (apply old-fun args)))

(defun su--nadvice-supress-find-file-hook (old-fun &rest args)
  (cl-letf* ((old-aff (symbol-function #'after-find-file))
             ((symbol-function #'after-find-file)
              (lambda (&rest args)
                (let ((find-file-hook))
                  (apply old-aff args)))))
    (apply old-fun args)))

(defun su--before-save-hook ()
  "Switch the visiting file to a TRAMP su or sudo name if applicable"
  (when (and (buffer-modified-p)
             (not (su--root-file-name-p buffer-file-name))
             (or (not (su--check-passwordless-sudo))
                 (yes-or-no-p "File is not writable. Save with root? ")))
    (let ((change-major-mode-with-file-name nil))
      (set-visited-file-name (su--make-root-file-name buffer-file-name) t t))
    (remove-hook 'before-save-hook #'su--before-save-hook t)))

(defun su--nadvice/find-file-noselect (old-fun &rest args)
  (cl-letf* ((old-fwp (symbol-function #'file-writable-p))
             ((symbol-function #'file-writable-p)
              (lambda (&rest iargs)
                (or (member 'su-auto-save-mode first-change-hook)
                    (bound-and-true-p su-auto-save-mode)
                    (apply old-fwp iargs)))))
    (apply old-fun args)))

(defun su--notify-insufficient-permissions ()
  (message "Modifications will require a change of permissions to save."))

(defun su--edit-file-as-root-maybe ()
  "Find file as root if necessary."
  (when (and buffer-file-name
             (not (file-writable-p buffer-file-name))
             (not (string= user-login-name
                           (nth 3 (file-attributes buffer-file-name 'string))))
             (not (su--root-file-name-p buffer-file-name)))

    (setq buffer-read-only nil)
    (add-hook 'first-change-hook #'su-auto-save-mode nil t)

    ;; This is kind of a hack, since I can't guarantee that this
    ;; message will be displayed last, so I just display it with a
    ;; delay.
    (run-with-idle-timer 0.5 nil #'su--notify-insufficient-permissions)))

;;;###autoload
(defun su ()
  "Find file as root"
  (interactive)
  (find-alternate-file (su--make-root-file-name buffer-file-name)))

;;;###autoload
(define-minor-mode su-auto-save-mode
  "Automatically save buffer as root"
  :lighter su-auto-save-mode-lighter
  (if su-auto-save-mode
      ;; Ensure that su-auto-save-mode is visible by moving it to the
      ;; beginning of the minor mode list
      (progn
        (let ((su-auto-save-mode-alist-entry
               (assoc 'su-auto-save-mode minor-mode-alist)))
          (setq minor-mode-alist
                (delete su-auto-save-mode-alist-entry minor-mode-alist))
          (push su-auto-save-mode-alist-entry minor-mode-alist))
        (add-hook 'before-save-hook #'su--before-save-hook nil t))
    (remove-hook 'before-save-hook #'su--before-save-hook t)))

;;;###autoload
(define-minor-mode su-mode
  "Automatically read and write files as users"
  :init-value nil
  :group 'su
  :global t
  (if su-mode
      (progn
        (when su-auto-make-directory
          (advice-add 'basic-save-buffer :around
                      #'su--nadvice-make-directory-auto-root)

          (when su-enable-helm-integration
            (with-eval-after-load 'helm-files
              (advice-add 'helm-find-file-or-marked :around
                          #'su--nadvice-make-directory-auto-root))))

        (when su-auto-write-file
          (add-hook 'find-file-hook #'su--edit-file-as-root-maybe)
          (advice-add 'find-file-noselect :around
                      #'su--nadvice/find-file-noselect)

          (when su-enable-semantic-integration
            (with-eval-after-load 'semantic/fw
              (advice-add 'semantic-find-file-noselect :around
                          #'su--nadvice-supress-find-file-hook))))

        (when su-auto-read-file
          (advice-add 'find-file-noselect-1 :around
                      #'su--nadvice-find-file-noselect-1)))

    (remove-hook 'find-file-hook #'su--edit-file-as-root-maybe)
    (advice-remove 'basic-save-buffer
                #'su--nadvice-make-directory-auto-root)
    (advice-remove 'helm-find-file-or-marked
                #'su--nadvice-make-directory-auto-root)
    (advice-remove 'find-file-noselect
                #'su--nadvice/find-file-noselect)
    (advice-remove 'semantic-find-file-noselect
                #'su--nadvice-supress-find-file-hook)
    (advice-remove 'find-file-noselect-1
                   #'su--nadvice-find-file-noselect-1)))

(provide 'su)

;;; su.el ends here

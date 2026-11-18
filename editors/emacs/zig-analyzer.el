;;; zig-analyzer.el --- Zig language server integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jinzhongjia

;; Author: jinzhongjia
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages tools
;; URL: https://github.com/jinzhongjia/zig-analyzer
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Registers the zig-analyzer language server with Eglot and adds commands for
;; the server's own requests.  It needs a Zig major mode such as `zig-mode' or
;; `zig-ts-mode' (both on MELPA), Eglot (built in since Emacs 29), and the
;; zig-analyzer server.
;;
;;     (require 'zig-analyzer)
;;     (zig-analyzer-mode 1)
;;
;; The server is `zig-analyzer-executable' when set, else the release installed
;; by `M-x zig-analyzer-install-server', else zig-analyzer in PATH.  That
;; command checks the release's minisign signature and SHA-256 before
;; installing it.
;; Settings are a plist in `zig-analyzer-settings'; see
;; `zig-analyzer.default.zon' in the zig-analyzer repository for the options.

;;; Code:

(require 'cl-lib)
(require 'eglot)
(require 'json)
(require 'project)
(require 'subr-x)

(defgroup zig-analyzer nil
  "Zig language server integration."
  :group 'languages
  :prefix "zig-analyzer-")

(defun zig-analyzer--default-install-directory ()
  "Return the default directory for releases installed by this package."
  (expand-file-name
   "emacs/zig-analyzer"
   (if (eq system-type 'windows-nt)
       (or (getenv "LOCALAPPDATA") "~/AppData/Local")
     (or (getenv "XDG_DATA_HOME") "~/.local/share"))))

(defcustom zig-analyzer-executable nil
  "Command that starts the zig-analyzer language server.
When nil, use the release installed by `zig-analyzer-install-server', else
`zig-analyzer' in PATH.  A non-nil value takes precedence over the installed
release, for example for a server built from source."
  :type '(choice (const :tag "Installed release, else PATH" nil) string)
  :group 'zig-analyzer)

(defcustom zig-analyzer-install-directory
  (zig-analyzer--default-install-directory)
  "Directory in which `zig-analyzer-install-server' installs releases.
A release goes into a subdirectory named after it, and `current' names the
release in use."
  :type 'directory
  :group 'zig-analyzer)

(defcustom zig-analyzer-releases-url
  "https://github.com/jinzhongjia/zig-analyzer/releases"
  "Release page that `zig-analyzer-install-server' downloads from."
  :type 'string
  :group 'zig-analyzer)

(defcustom zig-analyzer-public-key
  "RWRbma3B4tRgvIsJxiSxTvwoOWB6wvqxTEDgWVaJk0XMSeW9THbHBVj+"
  "Minisign public key of the zig-analyzer release key.
This is the key in `minisign.pub' in the zig-analyzer repository."
  :type 'string
  :group 'zig-analyzer)

(defcustom zig-analyzer-minisign-executable "minisign"
  "Minisign executable used to check release signatures.
When nil or an empty string, the signature of `SHA256SUMS' is not checked,
with a warning; only the SHA-256 of the archive is checked.  A non-nil value
must name an executable."
  :type '(choice (const :tag "Do not check the signature" nil) string)
  :group 'zig-analyzer)

(defcustom zig-analyzer-settings nil
  "Settings sent to zig-analyzer as initializationOptions.

The value is a plist with the structure of `zig-analyzer.default.zon':
`.build = .{ .args = .{\"-Dfoo\"} }' is
`(:build (:args [\"-Dfoo\"]))'.  JSON arrays are vectors and JSON false is
`:json-false'.  Settings in a project's `zig-analyzer.zon' take precedence
over this value."
  :type '(plist :key-type symbol :value-type sexp)
  :group 'zig-analyzer)

(defcustom zig-analyzer-request-timeout 60
  "Seconds to wait for a reply to a zig-analyzer request."
  :type 'number
  :group 'zig-analyzer)

(defvar zig-analyzer--registered-program nil
  "The `eglot-server-programs' entry added by `zig-analyzer-setup'.")

(defconst zig-analyzer--hooks '(zig-mode-hook zig-ts-mode-hook)
  "Major mode hooks in which `zig-analyzer-mode' starts Eglot.")

(defconst zig-analyzer--optimize-modes '("ReleaseSafe" "ReleaseFast")
  "Optimize modes of published zig-analyzer releases.")

(defun zig-analyzer--executable-name ()
  "Return the file name of the server executable on this system."
  (if (eq system-type 'windows-nt) "zig-analyzer.exe" "zig-analyzer"))

(defun zig-analyzer--target ()
  "Return `<arch>-<os>' of the release for this system, or nil."
  (let* ((configuration (downcase system-configuration))
         (arch (cond ((string-match-p "\\`\\(x86_64\\|amd64\\)" configuration)
                      "x86_64")
                     ((string-match-p "\\`\\(aarch64\\|arm64\\)" configuration)
                      "aarch64")))
         (os (cond ((eq system-type 'gnu/linux) "linux")
                   ((eq system-type 'darwin) "macos")
                   ((eq system-type 'windows-nt) "windows"))))
    (when (and arch os)
      (concat arch "-" os))))

(defun zig-analyzer-installed ()
  "Return (EXE . RELEASE) for the installed server, or nil.
RELEASE is the directory named by `current' in
`zig-analyzer-install-directory'."
  (let* ((dir (expand-file-name zig-analyzer-install-directory))
         (current (expand-file-name "current" dir)))
    (when (file-readable-p current)
      (let ((release (string-trim
                      (with-temp-buffer
                        (insert-file-contents current)
                        (buffer-string)))))
        (when (string-match-p "\\`zig-analyzer-v[0-9A-Za-z._-]+\\'" release)
          (let ((exe (expand-file-name
                      (concat release "/" (zig-analyzer--executable-name))
                      dir)))
            (when (file-executable-p exe)
              (cons exe release))))))))

(defun zig-analyzer--command ()
  "Return the server command: the configured one, the installed one, or PATH."
  (or (and zig-analyzer-executable
           (not (string-empty-p zig-analyzer-executable))
           zig-analyzer-executable)
      (car (zig-analyzer-installed))
      "zig-analyzer"))

(defun zig-analyzer--server-program ()
  "Return the `eglot-server-programs' entry for zig-analyzer."
  (cons '(zig-mode zig-ts-mode)
        (append (list (zig-analyzer--command))
                (when zig-analyzer-settings
                  (list :initializationOptions zig-analyzer-settings)))))

(defun zig-analyzer--without-workspace-configuration (configuration)
  "Return CONFIGURATION without its zig-analyzer section."
  (if (or (null configuration)
          (and (listp configuration) (not (functionp configuration))))
      (cl-loop for (key value) on configuration by #'cddr
               unless (eq key :zig-analyzer)
               append (list key value))
    configuration))

(defun zig-analyzer--workspace-configuration (configuration settings)
  "Return CONFIGURATION with its zig-analyzer section set to SETTINGS.
Remove the section when SETTINGS is nil.  Leave a function (a per-project
configuration) unchanged."
  (if (or (null configuration)
          (and (listp configuration) (not (functionp configuration))))
      (if settings
          (plist-put (copy-sequence configuration) :zig-analyzer settings)
        (zig-analyzer--without-workspace-configuration configuration))
    configuration))

(defun zig-analyzer--project-marker-p (directory)
  "Return non-nil when DIRECTORY has `build.zig' or `.git', by exact name.

Comparing directory entries keeps `Build.zig' from matching on
case-insensitive file systems; `file-exists-p' would find the standard
library's `std/Build.zig' for `build.zig'."
  (when-let ((entries (ignore-errors (directory-files directory nil nil t))))
    (or (member "build.zig" entries)
        (member ".git" entries))))

(defun zig-analyzer--project (dir)
  "Return the Zig project root above DIR for `project-find-functions'.

The root is the nearest directory with `build.zig' or `.git'.  This keeps a
Zig project inside a larger repository from being analyzed as part of the
repository root, and keeps a file in `src' from making `src' its own root."
  (when (or (derived-mode-p 'zig-mode) (derived-mode-p 'zig-ts-mode))
    (when-let ((root (locate-dominating-file
                      dir #'zig-analyzer--project-marker-p)))
      (cons 'transient (directory-file-name (expand-file-name root))))))

;;;###autoload
(defun zig-analyzer-setup ()
  "Register zig-analyzer with Eglot for Zig and ZON buffers.

This only adds the server to `eglot-server-programs'.  Use
`zig-analyzer-mode' to also start Eglot in Zig buffers."
  (interactive)
  (require 'eglot)
  (when zig-analyzer--registered-program
    (setq eglot-server-programs
          (delete zig-analyzer--registered-program eglot-server-programs)))
  (setq zig-analyzer--registered-program (zig-analyzer--server-program))
  (setq eglot-server-programs
        (cons zig-analyzer--registered-program eglot-server-programs))
  (add-to-list 'project-find-functions #'zig-analyzer--project)
  (setq-default eglot-workspace-configuration
                (zig-analyzer--workspace-configuration
                 (default-value 'eglot-workspace-configuration)
                 zig-analyzer-settings))
  (message "zig-analyzer: registered with Eglot"))

;;;###autoload
(define-minor-mode zig-analyzer-mode
  "Start the zig-analyzer server for Zig and ZON buffers.

When enabled, register zig-analyzer with Eglot and call `eglot-ensure' in
`zig-mode' and `zig-ts-mode' buffers."
  :global t
  :group 'zig-analyzer
  (if zig-analyzer-mode
      (progn
        (zig-analyzer-setup)
        (dolist (hook zig-analyzer--hooks)
          (add-hook hook #'eglot-ensure)))
    (dolist (hook zig-analyzer--hooks)
      (remove-hook hook #'eglot-ensure))
    (setq project-find-functions
          (delete #'zig-analyzer--project project-find-functions))
    (setq-default eglot-workspace-configuration
                  (zig-analyzer--without-workspace-configuration
                   (default-value 'eglot-workspace-configuration)))
    (when zig-analyzer--registered-program
      (setq eglot-server-programs
            (delete zig-analyzer--registered-program eglot-server-programs))
      (setq zig-analyzer--registered-program nil))))

(defun zig-analyzer--current-server ()
  "Return the Eglot server that serves the current buffer."
  (or (eglot-current-server)
      (user-error "No zig-analyzer server for this buffer; start Eglot in a Zig buffer")))

(defun zig-analyzer--request (method params)
  "Send METHOD (a keyword) with PARAMS to the current zig-analyzer server."
  (jsonrpc-request (zig-analyzer--current-server) method params
                   :timeout zig-analyzer-request-timeout))

(declare-function eglot--path-to-uri "eglot" (path))

(defun zig-analyzer--path-to-uri (path)
  "Return PATH as a file URI, for the Eglot version in use."
  (if (fboundp 'eglot-path-to-uri)
      (eglot-path-to-uri path)
    (eglot--path-to-uri path)))

(defun zig-analyzer--text-document ()
  "Return the textDocument parameter for the current buffer."
  (unless buffer-file-name
    (user-error "The buffer is not visiting a file"))
  `(:textDocument (:uri ,(zig-analyzer--path-to-uri buffer-file-name))))

;;; Installing releases

(defun zig-analyzer--executable-p (program)
  "Return non-nil when PROGRAM is an executable on this system."
  (if (file-name-absolute-p program)
      (file-executable-p program)
    (executable-find program)))

(defun zig-analyzer--run (program args &optional what)
  "Run PROGRAM with ARGS and return its output.
WHAT describes the action in an error message; it defaults to PROGRAM."
  (unless (zig-analyzer--executable-p program)
    (error "zig-analyzer: `%s` is not installed%s" program
           (if what (format " (%s)" what) "")))
  (with-temp-buffer
    (let ((status (apply #'call-process program nil (list (current-buffer) t)
                         nil args)))
      (unless (and (integerp status) (zerop status))
        (let ((output (string-trim (buffer-string))))
          (error "zig-analyzer: %s failed%s"
                 (or what program)
                 (if (string-empty-p output) "" (concat ": " output)))))
      (string-trim (buffer-string)))))

(defun zig-analyzer--download (url file)
  "Download URL to FILE with curl."
  (condition-case err
      (zig-analyzer--run "curl"
                         (list "-fsSL" "--proto" "=https,file"
                               "--retry" "3" "--connect-timeout" "30"
                               "-o" file url)
                         (format "downloading %s" url))
    (error
     (error "zig-analyzer: Cannot download %s: %s"
            url (error-message-string err)))))

(defun zig-analyzer--read-file (file)
  "Return the contents of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun zig-analyzer--sha256 (file)
  "Return the SHA-256 of FILE as a hexadecimal string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun zig-analyzer--hash-from-sums (sums archive)
  "Return the SHA-256 that SUMS lists for ARCHIVE, or nil."
  (let (hash)
    (dolist (line (split-string (zig-analyzer--read-file sums) "\n"))
      (setq line (string-remove-suffix "\r" line))
      (when (string-match "\\`\\([0-9a-fA-F]\\{64\\}\\)  \\(.+\\)\\'" line)
        (when (equal (match-string 2 line) archive)
          (setq hash (downcase (match-string 1 line))))))
    hash))

(defun zig-analyzer--trusted-comment-from-signature (file)
  "Return the trusted comment in minisign signature FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (forward-line 2)
    (when (looking-at "^trusted comment: \\(.*\\)$")
      (string-trim (match-string 1)))))

(defun zig-analyzer--verify-signature (sums signature)
  "Verify the minisign SIGNATURE of SUMS and return its trusted comment.
When `zig-analyzer-minisign-executable' is nil or empty, only read the
comment and warn that the signature is not checked."
  (let ((minisign zig-analyzer-minisign-executable))
    (if (and minisign (not (string-empty-p minisign)))
        (let ((output (progn
                        (unless (zig-analyzer--executable-p minisign)
                          (error "zig-analyzer: `%s` is not installed; install minisign or set `zig-analyzer-minisign-executable' to nil"
                                 minisign))
                        (condition-case err
                            (zig-analyzer--run
                             minisign
                             (list "-V" "-Q" "-P" (string-trim zig-analyzer-public-key)
                                   "-x" signature "-m" sums)
                             "checking the SHA256SUMS signature")
                          (error
                           (error "zig-analyzer: SHA256SUMS: the signature does not verify with the release key (%s)"
                                  (error-message-string err)))))))
          (when (string-empty-p output)
            (error "zig-analyzer: SHA256SUMS: the signature has no trusted comment"))
          (if (string-match "\\`trusted comment: \\(.*\\)\\'" output)
              (match-string 1 output)
            output))
      (message "zig-analyzer: minisign is not installed, so the signature of SHA256SUMS is not checked")
      (or (zig-analyzer--trusted-comment-from-signature signature)
          (error "zig-analyzer: SHA256SUMS: no trusted comment")))))

(defun zig-analyzer--tar-program ()
  "Return the tar executable to unpack a release with."
  (if (eq system-type 'windows-nt)
      (let ((path (expand-file-name
                   "System32/tar.exe"
                   (or (getenv "SystemRoot") "C:/Windows"))))
        (if (file-executable-p path) path "tar"))
    "tar"))

(defun zig-analyzer--extract (archive directory)
  "Unpack ARCHIVE into DIRECTORY."
  (let ((zip (eq system-type 'windows-nt)))
    (zig-analyzer--run (zig-analyzer--tar-program)
                       (list (if zip "-xf" "-xzf") archive "-C" directory)
                       (format "unpacking %s" (file-name-nondirectory archive)))))

(defun zig-analyzer--write-current (directory release)
  "Make RELEASE the current release in DIRECTORY."
  (let ((current (expand-file-name "current" directory))
        (tmp (make-temp-file (expand-file-name ".current-" directory))))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert release "\n"))
          (rename-file tmp current t))
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun zig-analyzer--remove-others (directory release)
  "Remove installed releases in DIRECTORY other than RELEASE."
  (dolist (entry (directory-files directory nil "\\`zig-analyzer-"))
    (unless (equal entry release)
      (ignore-errors
        (delete-directory (expand-file-name entry directory) t)))))

(defun zig-analyzer--install (version optimize)
  "Install a zig-analyzer release of VERSION and OPTIMIZE.
See `zig-analyzer-install-server'."
  (setq version (if version
                    (string-trim (if (symbolp version)
                                     (symbol-name version)
                                   version))
                  nil))
  (setq version (unless (or (null version)
                            (string-empty-p version)
                            (equal version "latest"))
                  version))
  (setq optimize (string-trim
                  (or (if (symbolp optimize) (symbol-name optimize) optimize)
                      "ReleaseSafe")))
  (unless (member optimize zig-analyzer--optimize-modes)
    (error "zig-analyzer: Unknown optimize mode %s" optimize))
  (when (and version
             (not (string-match-p "\\`v[0-9]+\\.[0-9]+\\.[0-9]+[0-9A-Za-z.-]*\\'"
                                  version)))
    (error "zig-analyzer: %S is not a release tag (such as v0.1.1)" version))
  (let ((target (zig-analyzer--target)))
    (unless target
      (error "zig-analyzer: No release for %s; build zig-analyzer from source and set `zig-analyzer-executable'"
             system-configuration))
    (let ((directory (expand-file-name zig-analyzer-install-directory))
          (temporary nil))
      (make-directory directory t)
      (setq temporary (make-temp-file (expand-file-name ".tmp-" directory) t))
      (unwind-protect
          (let* ((base (if version
                           (format "%s/download/%s" zig-analyzer-releases-url version)
                         (format "%s/latest/download" zig-analyzer-releases-url)))
                 (sums (expand-file-name "SHA256SUMS" temporary))
                 (signature (expand-file-name "SHA256SUMS.minisig" temporary)))
            (message "zig-analyzer: looking up %s" (or version "the latest release"))
            (zig-analyzer--download (concat base "/SHA256SUMS") sums)
            (zig-analyzer--download (concat base "/SHA256SUMS.minisig") signature)
            (let* ((comment (zig-analyzer--verify-signature sums signature))
                   (tag (and (string-match
                              "\\`zig-analyzer \\(v[0-9A-Za-z._-]+\\)\\'" comment)
                             (match-string 1 comment))))
              (unless tag
                (error "zig-analyzer: SHA256SUMS: unexpected trusted comment %S" comment))
              (when (and version (not (equal tag version)))
                (error "zig-analyzer: SHA256SUMS is signed for %s, not %s"
                       tag version))
              (let* ((release (format "zig-analyzer-%s-%s-%s"
                                      tag target optimize))
                     (archive-name (concat release
                                           (if (eq system-type 'windows-nt)
                                               ".zip" ".tar.gz")))
                     (hash (zig-analyzer--hash-from-sums sums archive-name))
                     (exe-name (zig-analyzer--executable-name))
                     (exe (expand-file-name (concat release "/" exe-name)
                                            directory)))
                (unless hash
                  (error "zig-analyzer: %s has no %s" tag archive-name))
                (unless (and (zig-analyzer-installed)
                             (equal (cdr (zig-analyzer-installed)) release))
                  (message "zig-analyzer: downloading %s" archive-name)
                  (let ((archive (expand-file-name archive-name temporary)))
                    ;; From the checked release: latest may have moved on since
                    ;; SHA256SUMS was downloaded.
                    (zig-analyzer--download
                     (format "%s/download/%s/%s" zig-analyzer-releases-url
                             tag archive-name)
                     archive)
                    (unless (equal (zig-analyzer--sha256 archive) hash)
                      (error "zig-analyzer: %s: the SHA-256 does not match SHA256SUMS"
                             archive-name))
                    (zig-analyzer--extract archive temporary)
                    (let ((unpacked (expand-file-name
                                     (concat release "/" exe-name) temporary)))
                      (unless (file-exists-p unpacked)
                        (error "zig-analyzer: %s has no %s/%s"
                               archive-name release exe-name))
                      (unless (eq system-type 'windows-nt)
                        (set-file-modes unpacked #o755))
                      (unless (file-executable-p unpacked)
                        (error "zig-analyzer: %s has no executable %s/%s"
                               archive-name release exe-name))
                      (zig-analyzer--run unpacked (list "--version")
                                         "the downloaded server does not run")
                      (let ((destination (expand-file-name release directory)))
                        (when (file-exists-p destination)
                          (delete-directory destination t))
                        (rename-file (expand-file-name release temporary)
                                     destination)
                        (zig-analyzer--write-current directory release)
                        (zig-analyzer--remove-others directory release)))))
                (cons exe release))))
        (when (and temporary (file-directory-p temporary))
          (delete-directory temporary t))))))

(defun zig-analyzer--restart-server (server buffer)
  "Restart SERVER, with the server program of BUFFER's project."
  (eglot-shutdown server nil 5)
  (with-current-buffer buffer
    (apply #'eglot--connect (eglot--guess-contact))))

;;;###autoload
(defun zig-analyzer-install-server (&optional version optimize)
  "Download and install a zig-analyzer release.
VERSION is \"latest\" (the default) or a release tag such as \"v0.1.1\".
OPTIMIZE is \"ReleaseSafe\" (the default) or \"ReleaseFast\".  The release's
SHA256SUMS must be signed by `zig-analyzer-public-key' and name the release,
and the archive must have the SHA-256 that SHA256SUMS lists for it.  The
release goes into `zig-analyzer-install-directory' and is used by default;
a non-nil `zig-analyzer-executable' stays in use instead."
  (interactive
   (list (read-string "zig-analyzer release (latest or a tag such as v0.1.1): "
                      "latest")
         (completing-read "Optimize: " zig-analyzer--optimize-modes
                          nil t nil nil "ReleaseSafe")))
  (let ((server (ignore-errors (eglot-current-server)))
        (buffer (current-buffer)))
    (let ((installed (zig-analyzer--install version optimize)))
      (message "zig-analyzer: installed %s" (cdr installed))
      ;; The Eglot entry captured the previous installed path.
      (when (and (null zig-analyzer-executable) zig-analyzer--registered-program)
        (zig-analyzer-setup))
      (cond
       (zig-analyzer-executable
        (message "zig-analyzer-executable is set, so the installed release is not used"))
       ((and server zig-analyzer--registered-program)
        (condition-case err
            (zig-analyzer--restart-server server buffer)
          (error
           (message "zig-analyzer: installed, but restarting Eglot failed: %s"
                    (error-message-string err)))))
       (t
        (message "zig-analyzer: new Zig buffers use the installed release")))
      installed)))

(defun zig-analyzer--display (name result)
  "Show RESULT in a `special-mode' buffer named after NAME."
  (let ((buffer (get-buffer-create (format "*zig-analyzer %s*" name))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((null result)
          (insert "(no result)\n"))
         ((stringp result)
          (insert result)
          (unless (bolp) (insert "\n")))
         (t
          (insert (json-encode result))
          (goto-char (point-min))
          (json-pretty-print-buffer)
          (unless (bolp) (insert "\n"))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))

;;;###autoload
(defun zig-analyzer-status ()
  "Show what the zig-analyzer server is doing."
  (interactive)
  (zig-analyzer--display
   "status"
   (zig-analyzer--request :zig-analyzer/status nil)))

;;;###autoload
(defun zig-analyzer-file-status ()
  "Show how zig-analyzer treats the current file."
  (interactive)
  (zig-analyzer--display
   "file status"
   (zig-analyzer--request :zig-analyzer/fileStatus
                          (zig-analyzer--text-document))))

;;;###autoload
(defun zig-analyzer-syntax-tree ()
  "Show the syntax tree of the current file."
  (interactive)
  (zig-analyzer--display
   "syntax tree"
   (zig-analyzer--request :zig-analyzer/syntaxTree
                          (zig-analyzer--text-document))))

;;;###autoload
(defun zig-analyzer-module-graph ()
  "Show the module graph of the projects of the current server."
  (interactive)
  (zig-analyzer--display
   "module graph"
   (zig-analyzer--request :zig-analyzer/moduleGraph nil)))

;;;###autoload
(defun zig-analyzer-reload-workspace ()
  "Rerun build.zig and reload the projects."
  (interactive)
  (zig-analyzer--request :zig-analyzer/reloadWorkspace nil)
  (message "zig-analyzer: reloading the workspace"))

;;;###autoload
(defun zig-analyzer-restart ()
  "Restart the zig-analyzer server of the current buffer."
  (interactive)
  (let ((server (zig-analyzer--current-server))
        (buffer (current-buffer)))
    (zig-analyzer--restart-server server buffer)))

;;;###autoload
(defun zig-analyzer-show-log ()
  "Show the Eglot events buffer of the current server."
  (interactive)
  (eglot-events-buffer (zig-analyzer--current-server)))

(provide 'zig-analyzer)

;;; zig-analyzer.el ends here

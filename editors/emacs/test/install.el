;;; install.el --- install test for zig-analyzer.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests `zig-analyzer-install-server' on fake releases in a local directory,
;; signed by test/release.mjs.  Run from editors/emacs; needs node, minisign,
;; curl, and tar:
;;
;;     emacs -Q --batch -L . -l test/install.el

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'zig-analyzer)

(defvar zig-analyzer-install-test-failures 0)

(defun zig-analyzer-install-test--check (condition what)
  (message "%s %s" (if condition "ok  " "FAIL") what)
  (unless condition
    (cl-incf zig-analyzer-install-test-failures)))

(defun zig-analyzer-install-test--run (program &rest args)
  (with-temp-buffer
    (let ((status (apply #'call-process program nil (list (current-buffer) t)
                         nil args)))
      (unless (and (integerp status) (zerop status))
        (error "%s failed: %s" program (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun zig-analyzer-install-test--install-error (version optimize)
  (condition-case err
      (progn
        (zig-analyzer-install-server version optimize)
        nil)
    (error (error-message-string err))))

(defun zig-analyzer-install-test--tmp-leftovers (directory)
  (seq-filter (lambda (name) (string-prefix-p ".tmp-" name))
              (directory-files directory)))

(let* ((root (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))
       (tmp (file-truename (make-temp-file "zig-analyzer-install-" t)))
       (releases (expand-file-name "releases" tmp))
       (data (expand-file-name "data" tmp))
       (keyfile (expand-file-name "key.pem" tmp))
       (other-keyfile (expand-file-name "other.pem" tmp))
       (fake (expand-file-name "fake-zig-analyzer" tmp))
       (script (expand-file-name "test/release.mjs" root))
       (target (zig-analyzer--target)))
  (unwind-protect
      (progn
        (unless (and (executable-find "node")
                     (executable-find "minisign")
                     (executable-find "curl")
                     (executable-find "tar"))
          (error "the install test needs node, minisign, curl, and tar"))
        (unless target
          (error "no release target for this system"))
        (when (file-readable-p (expand-file-name "../../minisign.pub" root))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "../../minisign.pub" root))
            (goto-char (point-min))
            (forward-line 1)
            (zig-analyzer-install-test--check
             (equal (string-trim
                     (buffer-substring (point) (line-end-position)))
                    zig-analyzer-public-key)
             "the release key is that of minisign.pub")))
        (write-region
         "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo zig-analyzer 0.0.0; fi\n"
         nil fake)
        (set-file-modes fake #o755)
        (setq zig-analyzer-install-directory data
              zig-analyzer-releases-url (concat "file://" releases)
              zig-analyzer-minisign-executable "minisign"
              zig-analyzer-executable nil
              zig-analyzer-public-key
              (zig-analyzer-install-test--run "node" script "key" keyfile))
        (zig-analyzer-install-test--run "node" script "key" other-keyfile)

        (cl-labels
            ((release-name (tag optimize)
               (format "zig-analyzer-%s-%s-%s" tag target optimize))
             (archive-name (tag optimize)
               (concat (release-name tag optimize) ".tar.gz"))
             (make-release (tag &optional comment optimize key)
               (let* ((optimize (or optimize "ReleaseSafe"))
                      (dir (expand-file-name (concat "download/" tag) releases))
                      (name (release-name tag optimize))
                      (stage (expand-file-name (concat "stage/" name) tmp))
                      (archive (expand-file-name (archive-name tag optimize) dir)))
                 (make-directory dir t)
                 (make-directory stage t)
                 (copy-file fake (expand-file-name "zig-analyzer" stage) t)
                 (set-file-modes (expand-file-name "zig-analyzer" stage) #o755)
                 (zig-analyzer-install-test--run
                  "tar" "-czf" archive "-C" (expand-file-name "stage" tmp) name)
                 (zig-analyzer-install-test--run
                  "node" script "sign" (or key keyfile) dir
                  (format "zig-analyzer %s" (or comment tag)))
                 dir))
             (make-latest (tag)
               (let ((from (expand-file-name (concat "download/" tag) releases))
                     (to (expand-file-name "latest/download" releases)))
                 (when (file-directory-p (expand-file-name "latest" releases))
                   (delete-directory (expand-file-name "latest" releases) t))
                 (make-directory (expand-file-name "latest" releases) t)
                 (copy-directory from to t t t)))
             (installed-release ()
               (cdr (zig-analyzer-installed))))

          (zig-analyzer-install-test--check
           (string-match-p "\\`\\(x86_64\\|aarch64\\)-\\(linux\\|macos\\|windows\\)\\'"
                           target)
           (format "the release target is %s" target))

          (make-release "v9.9.8" nil "ReleaseSafe")
          (make-release "v9.9.8" nil "ReleaseFast")
          (make-release "v9.9.9" nil "ReleaseSafe")
          (make-latest "v9.9.9")
          (zig-analyzer-install-test--check
           (null (zig-analyzer-installed))
           "nothing is installed before the first install")

          (let ((installed (zig-analyzer-install-server "latest" "ReleaseSafe")))
            (zig-analyzer-install-test--check
             (equal (cdr installed)
                    (release-name "v9.9.9" "ReleaseSafe"))
             "the latest release installs"))
          (zig-analyzer-install-test--check
           (equal (installed-release) (release-name "v9.9.9" "ReleaseSafe"))
           "the installed release is found")
          (zig-analyzer-install-test--check
           (equal (zig-analyzer--command)
                  (car (zig-analyzer-installed)))
           "the installed server is the default command")
          (let ((zig-analyzer-executable "/opt/zig-analyzer"))
            (zig-analyzer-install-test--check
             (equal (zig-analyzer--command) "/opt/zig-analyzer")
             "a configured server takes precedence"))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "current" data))
            (zig-analyzer-install-test--check
             (equal (split-string (buffer-string) "\n" t)
                    (list (release-name "v9.9.9" "ReleaseSafe")))
             "current names the installed release"))
          (zig-analyzer-install-test--check
           (null (zig-analyzer-install-test--tmp-leftovers data))
           "an install leaves no temporary directory")

          (zig-analyzer-install-server "v9.9.8" "ReleaseFast")
          (zig-analyzer-install-test--check
           (equal (installed-release) (release-name "v9.9.8" "ReleaseFast"))
           "a given release and optimize mode install")
          (zig-analyzer-install-test--check
           (not (file-directory-p
                 (expand-file-name (release-name "v9.9.9" "ReleaseSafe") data)))
           "the previous release is removed")

          ;; The installed release needs no archive, but its metadata is still checked
          (delete-file
           (expand-file-name
            (archive-name "v9.9.8" "ReleaseFast")
            (expand-file-name "download/v9.9.8" releases)))
          (zig-analyzer-install-test--check
           (null (zig-analyzer-install-test--install-error "v9.9.8" "ReleaseFast"))
           "reinstalling the installed release needs no archive")

          (make-release "v9.9.7" nil "ReleaseSafe" other-keyfile)
          (zig-analyzer-install-test--check
           (string-match-p "signature does not verify"
                           (or (zig-analyzer-install-test--install-error
                                "v9.9.7" "ReleaseSafe")
                               ""))
           "a release signed with another key is rejected")

          (make-release "v9.9.6" "v9.9.5" "ReleaseSafe")
          (zig-analyzer-install-test--check
           (string-match-p "signed for v9.9.5"
                           (or (zig-analyzer-install-test--install-error
                                "v9.9.6" "ReleaseSafe")
                               ""))
           "a release signed for another tag is rejected")

          (make-release "v9.9.4" nil "ReleaseSafe")
          (zig-analyzer-install-test--check
           (string-match-p "has no zig-analyzer-v9.9.4"
                           (or (zig-analyzer-install-test--install-error
                                "v9.9.4" "ReleaseFast")
                               ""))
           "a release without the requested archive is rejected")

          (let ((archive (expand-file-name (archive-name "v9.9.3" "ReleaseSafe")
                                           (make-release "v9.9.3"))))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally archive)
              (let ((contents (buffer-string)))
                (with-temp-file archive
                  (set-buffer-multibyte nil)
                  (insert contents "x"))))
            (zig-analyzer-install-test--check
             (string-match-p "SHA-256 does not match"
                             (or (zig-analyzer-install-test--install-error
                                  "v9.9.3" "ReleaseSafe")
                                 ""))
             "an archive with another SHA-256 is rejected"))

          (zig-analyzer-install-test--check
           (string-match-p "cannot download"
                           (or (zig-analyzer-install-test--install-error
                                "v9.9.2" "ReleaseSafe")
                               ""))
           "a release that does not exist is rejected")
          (zig-analyzer-install-test--check
           (string-match-p "not a release tag"
                           (or (zig-analyzer-install-test--install-error
                                "nightly" "ReleaseSafe")
                               ""))
           "a version that is no tag is rejected")
          (zig-analyzer-install-test--check
           (string-match-p "Unknown optimize mode"
                           (or (zig-analyzer-install-test--install-error
                                "v9.9.8" "Debug")
                               ""))
           "an unknown optimize mode is rejected")

          (zig-analyzer-install-test--check
           (equal (installed-release) (release-name "v9.9.8" "ReleaseFast"))
           "rejected installs change nothing")
          (zig-analyzer-install-test--check
           (null (zig-analyzer-install-test--tmp-leftovers data))
           "rejected installs leave no temporary directory")

          (let ((zig-analyzer-minisign-executable
                 "zig-analyzer-test-no-such-minisign"))
            (zig-analyzer-install-test--check
             (string-match-p "is not installed"
                             (or (zig-analyzer-install-test--install-error
                                  "v9.9.8" "ReleaseSafe")
                                 ""))
             "a configured minisign that is missing fails the install"))))
    (when (file-directory-p tmp)
      (delete-directory tmp t))))

(kill-emacs (if (> zig-analyzer-install-test-failures 0) 1 0))

;;; install.el ends here

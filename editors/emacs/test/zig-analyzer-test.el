;;; zig-analyzer-test.el --- tests for zig-analyzer.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from editors/emacs:
;;
;;     emacs -Q --batch -L . -l test/zig-analyzer-test.el \
;;       -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'zig-analyzer)

(declare-function zig-mode "zig-mode" ())
(declare-function zig-ts-mode "zig-ts-mode" ())

;; `zig-mode' and `zig-ts-mode' are not dependencies of the package.  Define
;; minimal modes for the tests that use them.
(unless (fboundp 'zig-mode)
  (define-derived-mode zig-mode prog-mode "Zig"))
(unless (fboundp 'zig-ts-mode)
  (define-derived-mode zig-ts-mode prog-mode "Zig TS"))

(ert-deftest zig-analyzer-server-program ()
  (let ((zig-analyzer-executable "/opt/zig-analyzer")
        (zig-analyzer-settings nil))
    (should (equal (zig-analyzer--server-program)
                   '((zig-mode zig-ts-mode) "/opt/zig-analyzer"))))
  (let ((zig-analyzer-executable "zig-analyzer")
        (zig-analyzer-settings '(:build (:args ["-Dfoo"]))))
    (should (equal (zig-analyzer--server-program)
                   '((zig-mode zig-ts-mode) "zig-analyzer"
                     :initializationOptions (:build (:args ["-Dfoo"])))))))

(ert-deftest zig-analyzer-setup-registers-and-replaces ()
  (let ((eglot-server-programs '(((zig-mode zig-ts-mode) . ("zls"))))
        (zig-analyzer-executable "zig-analyzer")
        (zig-analyzer-settings nil)
        (zig-analyzer--registered-program nil))
    (zig-analyzer-setup)
    (should (equal (car eglot-server-programs)
                   '((zig-mode zig-ts-mode) "zig-analyzer")))
    (should (equal (cdr eglot-server-programs)
                   '(((zig-mode zig-ts-mode) . ("zls")))))
    (let ((zig-analyzer-settings '(:build (:args ["-Dfoo"]))))
      (zig-analyzer-setup)
      (should (equal (car eglot-server-programs)
                     '((zig-mode zig-ts-mode) "zig-analyzer"
                       :initializationOptions (:build (:args ["-Dfoo"])))))
      (should (= 1 (seq-count (lambda (entry)
                                (equal (cadr entry) "zig-analyzer"))
                              eglot-server-programs))))))

(ert-deftest zig-analyzer-workspace-configuration ()
  (should (equal (zig-analyzer--workspace-configuration
                  nil '(:build (:args ["-Dfoo"])))
                 '(:zig-analyzer (:build (:args ["-Dfoo"])))))
  (should (equal (zig-analyzer--workspace-configuration
                  '(:other 1 :zig-analyzer (:old t))
                  '(:new t))
                 '(:other 1 :zig-analyzer (:new t))))
  (should (equal (zig-analyzer--workspace-configuration
                  '(:other 1 :zig-analyzer (:old t))
                  nil)
                 '(:other 1)))
  (should (equal (zig-analyzer--without-workspace-configuration
                  '(:other 1 :zig-analyzer (:x t)))
                 '(:other 1))))

(ert-deftest zig-analyzer-project-root ()
  (let* ((dir (file-truename (make-temp-file "zig-analyzer-project-" t)))
         (src (expand-file-name "src" dir)))
    (unwind-protect
        (progn
          (make-directory src)
          (with-temp-file (expand-file-name "build.zig" dir)
            (insert "pub fn build() void {}\n"))
          (with-temp-buffer
            (zig-mode)
            (should (equal (cdr (zig-analyzer--project src))
                           (expand-file-name dir))))
          (with-temp-buffer
            (fundamental-mode)
            (should-not (zig-analyzer--project src)))
          (delete-file (expand-file-name "build.zig" dir))
          (make-directory (expand-file-name ".git" dir))
          (with-temp-buffer
            (zig-mode)
            (should (equal (cdr (zig-analyzer--project src))
                           (expand-file-name dir))))
          ;; A differently cased name is not a project marker, even on a
          ;; case-insensitive file system.
          (delete-directory (expand-file-name ".git" dir))
          (with-temp-file (expand-file-name "src/Build.zig" dir)
            (insert "pub const name = \"Build\";\n"))
          (with-temp-buffer
            (zig-mode)
            (should-not (zig-analyzer--project src))
            (should-not (zig-analyzer--project-marker-p src))))
      (delete-directory dir t))))

(ert-deftest zig-analyzer-installed-release ()
  (let* ((dir (file-truename (make-temp-file "zig-analyzer-install-" t)))
         (release "zig-analyzer-v1.2.3-x86_64-linux-ReleaseSafe")
         (zig-analyzer-install-directory dir)
         (exe (expand-file-name
               (concat release "/" (zig-analyzer--executable-name)) dir)))
    (unwind-protect
        (progn
          (should-not (zig-analyzer-installed))
          (let ((zig-analyzer-executable nil))
            (should (equal (zig-analyzer--command) "zig-analyzer")))
          (make-directory (file-name-directory exe) t)
          (with-temp-file exe
            (insert "#!/bin/sh\n"))
          (set-file-modes exe #o755)
          (with-temp-file (expand-file-name "current" dir)
            (insert release "\n"))
          (should (equal (zig-analyzer-installed) (cons exe release)))
          (let ((zig-analyzer-executable nil)
                (zig-analyzer-settings nil))
            (should (equal (zig-analyzer--command) exe))
            (should (equal (zig-analyzer--server-program)
                           (list '(zig-mode zig-ts-mode) exe))))
          (let ((zig-analyzer-executable "/opt/zig-analyzer"))
            (should (equal (zig-analyzer--command) "/opt/zig-analyzer")))
          (delete-file (expand-file-name "current" dir))
          (should-not (zig-analyzer-installed)))
      (delete-directory dir t))))

(ert-deftest zig-analyzer-target ()
  (let ((target (zig-analyzer--target)))
    (when target
      (should (string-match-p
               "\\`\\(x86_64\\|aarch64\\)-\\(linux\\|macos\\|windows\\)\\'"
               target)))))

(ert-deftest zig-analyzer-mode-registers-and-unregisters ()
  (let ((eglot-server-programs nil)
        (project-find-functions nil)
        (zig-mode-hook nil)
        (zig-ts-mode-hook nil)
        (zig-analyzer-executable "zig-analyzer")
        (zig-analyzer-settings nil)
        (zig-analyzer--registered-program nil))
    (unwind-protect
        (progn
          (zig-analyzer-mode 1)
          (should zig-analyzer-mode)
          (should (memq #'eglot-ensure zig-mode-hook))
          (should (memq #'eglot-ensure zig-ts-mode-hook))
          (should (equal (car eglot-server-programs)
                         '((zig-mode zig-ts-mode) "zig-analyzer")))
          (should (memq #'zig-analyzer--project project-find-functions))
          (zig-analyzer-mode -1)
          (should-not zig-analyzer-mode)
          (should-not (memq #'eglot-ensure zig-mode-hook))
          (should-not (memq #'eglot-ensure zig-ts-mode-hook))
          (should-not (memq #'zig-analyzer--project project-find-functions))
          (should-not eglot-server-programs))
      (zig-analyzer-mode -1))))

(ert-deftest zig-analyzer-display-json-and-text ()
  (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
    (let ((buffer (zig-analyzer--display "test" '(:a 1 :b ["x"]))))
      (with-current-buffer buffer
        (should (derived-mode-p 'special-mode))
        (should (string-match-p "\"a\"" (buffer-string)))
        (should (string-match-p "\"x\"" (buffer-string)))))
    (let ((buffer (zig-analyzer--display "tree" "root\n  child\n")))
      (with-current-buffer buffer
        (should (equal (buffer-string) "root\n  child\n"))))))

(ert-deftest zig-analyzer-commands-send-requests ()
  (let ((requests nil)
        (buffer-file-name "/tmp/zig-analyzer-test.zig"))
    (cl-letf (((symbol-function 'zig-analyzer--current-server)
               (lambda () 'server))
              ((symbol-function 'jsonrpc-request)
               (lambda (_server method params &rest _)
                 (push (cons method params) requests)
                 (if (eq method :zig-analyzer/syntaxTree) "tree" '(:ok t))))
              ((symbol-function 'pop-to-buffer) #'identity)
              ((symbol-function 'message) #'ignore))
      (zig-analyzer-status)
      (zig-analyzer-file-status)
      (zig-analyzer-syntax-tree)
      (zig-analyzer-module-graph)
      (zig-analyzer-reload-workspace))
    (let* ((sent (nreverse requests))
           (file-status (cdr (nth 1 sent)))
           (uri (plist-get (plist-get file-status :textDocument) :uri)))
      (should (equal (mapcar #'car sent)
                     '(:zig-analyzer/status
                       :zig-analyzer/fileStatus
                       :zig-analyzer/syntaxTree
                       :zig-analyzer/moduleGraph
                       :zig-analyzer/reloadWorkspace)))
      (should (string-match-p "zig-analyzer-test\\.zig\\'" uri)))))

(provide 'zig-analyzer-test)

;;; zig-analyzer-test.el ends here

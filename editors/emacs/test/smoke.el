;;; smoke.el --- smoke test for zig-analyzer.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Opens a copy of editors/test-project with a real server.  Run from
;; editors/emacs; needs Zig 0.17 in PATH:
;;
;;     ZIG_ANALYZER=/path/to/zig-analyzer emacs -Q --batch -L . -l test/smoke.el

;;; Code:

(require 'cl-lib)
(require 'zig-analyzer)

;; The test environment has no Zig major mode package; the server integration
;; does not depend on one, so a minimal mode is enough here.
(unless (fboundp 'zig-mode)
  (define-derived-mode zig-mode prog-mode "Zig"))
(add-to-list 'auto-mode-alist '("\\.\\(zig\\|zon\\)\\'" . zig-mode))

(defvar zig-analyzer-smoke-failures 0)

(defun zig-analyzer-smoke--check (condition what)
  (message "%s %s" (if condition "ok  " "FAIL") what)
  (unless condition
    (cl-incf zig-analyzer-smoke-failures)))

(defun zig-analyzer-smoke--wait (predicate timeout)
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun zig-analyzer-smoke--first (value)
  "Return the first item of VALUE, which may be a vector, a list or one object."
  (cond ((vectorp value) (and (> (length value) 0) (aref value 0)))
        ((and (listp value) (keywordp (car value))) value)
        ((consp value) (car value))))

(defun zig-analyzer-smoke--pos (file needle delta)
  "Return the position of NEEDLE in FILE, DELTA characters after its start."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (unless (search-forward needle nil t)
      (error "not found: %s" needle))
    (list :line (1- (line-number-at-pos (match-beginning 0)))
          :character (+ (- (match-beginning 0) (line-beginning-position))
                        (or delta 0)))))

(defun zig-analyzer-smoke--request (method params)
  (jsonrpc-request (eglot-current-server) (intern (concat ":" method))
                   params :timeout 120))

(let* ((root (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))
       (source (expand-file-name "../test-project" root))
       (dir (file-truename (make-temp-file "zig-analyzer-emacs-" t))))
  (copy-directory source dir nil t t)
  ;; On case-insensitive file systems a lookup of `build.zig` from `src` finds
  ;; this file; the project root must still be `dir`.
  (with-temp-file (expand-file-name "src/Build.zig" dir)
    (insert "pub const name = \"Build\";\n"))
  (setq zig-analyzer-executable
        (or (getenv "ZIG_ANALYZER") "zig-analyzer"))
  (setq zig-analyzer-settings
        '(:log (:level "debug" :file "/tmp/zig-analyzer-emacs.log")))
  (zig-analyzer-setup)
  (let ((enable-local-variables nil))
    (find-file (expand-file-name "src/main.zig" dir)))
  (let ((main-buffer (current-buffer)))
    (apply #'eglot--connect (eglot--guess-contact))
    (unless (zig-analyzer-smoke--wait (lambda () (eglot-current-server)) 30)
      (error "the server did not start"))
    (with-current-buffer main-buffer
      (let ((server (eglot-current-server)))
        (zig-analyzer-smoke--request "zig-analyzer/waitIdle" nil)

        (let* ((main (expand-file-name "src/main.zig" dir))
               (doc `(:textDocument (:uri ,(zig-analyzer--path-to-uri main))))
               (status (zig-analyzer-smoke--request
                        "zig-analyzer/fileStatus" doc))
               (project (zig-analyzer-smoke--first
                         (plist-get status :projects))))
          (zig-analyzer-smoke--check
           (and project
                (equal (plist-get project :root) dir)
                (> (length (plist-get status :modules)) 0))
           "the file belongs to the build.zig project"))

        (let* ((call (zig-analyzer-smoke--pos
                      (expand-file-name "src/main.zig" dir)
                      "shapes.area(square)" 7))
               (doc `(:textDocument (:uri ,(zig-analyzer--path-to-uri
                                            (expand-file-name "src/main.zig" dir)))))
               (hover (zig-analyzer-smoke--request
                       "textDocument/hover" (append doc (list :position call))))
               (text (or (plist-get (plist-get hover :contents) :value) "")))
          (zig-analyzer-smoke--check
           (and (string-match-p "fn area(s: Square) u32" text)
                (string-match-p "The area of a square\\." text))
           "hover shows the signature and the doc comment")

          (let* ((definitions (zig-analyzer-smoke--request
                               "textDocument/definition"
                               (append doc (list :position call))))
                 (definition (zig-analyzer-smoke--first definitions))
                 (uri (or (plist-get definition :uri)
                          (plist-get definition :targetUri)))
                 (range (or (plist-get definition :range)
                            (plist-get definition :targetSelectionRange))))
            (zig-analyzer-smoke--check
             (and (string-match-p "src/shapes\\.zig\\'" uri)
                  (= (plist-get (plist-get range :start) :line)
                     (plist-get (zig-analyzer-smoke--pos
                                 (expand-file-name "src/shapes.zig" dir)
                                 "pub fn area" 0)
                                :line)))
             "definition in the other file"))

          (let ((references (zig-analyzer-smoke--request
                             "textDocument/references"
                             (append doc (list :position call
                                               :context '(:includeDeclaration t))))))
            (zig-analyzer-smoke--check
             (= 3 (length references))
             "references: declaration and two calls")))

        (zig-analyzer-file-status)
        (with-current-buffer "*zig-analyzer file status*"
          (zig-analyzer-smoke--check
           (and (string-match-p "\"projects\"" (buffer-string))
                (string-match-p (regexp-quote dir) (buffer-string)))
           "file status view"))

      (ignore-errors (eglot-shutdown server nil 5)))
    (kill-buffer main-buffer)))
  (delete-directory dir t)
  (kill-emacs (if (> zig-analyzer-smoke-failures 0) 1 0)))

;;; smoke.el ends here

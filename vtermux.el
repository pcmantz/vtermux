;;; vtermux.el --- Define multiple vterm-based interactive programs -*- lexical-binding: t; -*-

;; Author: Paul C. Mantz
;; Keywords: terminals, processes
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (vterm "0.0"))

;;; Commentary:
;; Provides `vtermux-define', a macro to declaratively define
;; project-scoped or directory-scoped vterm instances for arbitrary
;; CLI/TUI programs.  Think "tmux for Emacs" — each program gets its
;; own buffer family, scoped by directory method, with automatic
;; label management.
;;
;; Basic usage:
;;
;;   (require 'vtermux)
;;
;;   (vtermux-define claude                     ; M-x claude / claude-next / etc.
;;     :program "claude")
;;
;;   (vtermux-define btop)                      ; program defaults to symbol name
;;
;;   (vtermux-define opencode                   ; with arguments
;;     :program "opencode"
;;     :args "-m")
;;
;; Each definition generates the following commands:
;;   NAME        – launch an instance.  If no instance exists, creates
;;                 one.  If any exist, prompts for a label (defaults to
;;                 first unused number).
;;   NAME-new    – always create a new instance; always prompts for label.
;;   NAME-select – pick any live instance via completing-read.
;;   NAME-next   – cycle forward through instances in the current scope.
;;   NAME-prev   – cycle backward through instances in the current scope.
;;
;; Directory resolution (see `vtermux-command-directory'):
;;   :project — scope to the current project root (default)
;;   :buffer  — scope to the current buffer's directory
;;   :prompt  — always prompt for a directory
;; Prefix the command with \\[universal-argument] to prompt regardless.
;;
;; Buffer naming:
;;   *<bufname> - <directory>*                 — unnamed instance
;;   *<bufname> - <directory> (<label>)*       — labeled instance
;;
;; The label prompt defaults to the next unused integer when labels
;; follow the "1", "2", "3"… convention, matching tmux behavior.
;; You can always enter a custom label instead.
;;
;; When a program's process exits, the buffer is automatically killed
;; unless `vtermux-kill-buffer-on-exit' is nil.

;;; Code:
(require 'cl-lib)
(require 'vterm)

(defgroup vtermux nil
  "Manage multiple vterm-based application instances."
  :group 'vterm)

(defcustom vtermux-kill-buffer-on-exit t
  "Non-nil kills the buffer when the underlying process exits."
  :type 'boolean
  :group 'vtermux)

(defcustom vtermux-command-directory :project
  "Method for resolving the directory vtermux commands run in.
`:project' — use `project-root' of the current project (default)
`:buffer'  — use `default-directory' of the current buffer
`:prompt'  — always prompt for a directory
Overridden per-definition with the `:directory' keyword.
A prefix arg (\\[universal-argument]) always prompts."
  :type '(choice (const :tag "Project root" :project)
                 (const :tag "Buffer directory" :buffer)
                 (const :tag "Always prompt" :prompt))
  :group 'vtermux)

(defun vtermux--command-directory (&optional method prompt)
  "Resolve working directory for a vtermux command.
METHOD is `:project', `:buffer', `:prompt', or nil (use global default).
When PROMPT is non-nil, always ask the user.
Falls back to prompting the user on failure."
  (condition-case nil
      (if (or prompt (eq method :prompt))
          (read-directory-name "Directory: " default-directory nil t)
        (let ((effective (if (memq method '(:project :buffer :prompt))
                             method
                           vtermux-command-directory)))
          (pcase effective
            (:project
             (require 'project)
             (project-root
              (or (project-current) `(transient . ,default-directory))))
            (:buffer default-directory)
            (_ default-directory))))
    (error
     (read-directory-name "Directory: " default-directory nil t))))

(defun vtermux--next-label (buffers)
  "Return the first unused positive integer label for BUFFERS.
Extracts numeric labels from buffer names matching the vtermux
`(NUMBER)*' suffix and returns the smallest missing number as a string."
  (let (nums)
    (dolist (buf buffers)
      (when (and (buffer-live-p buf)
                 (string-match " (\\([0-9]+\\))\\*\\'" (buffer-name buf)))
        (push (string-to-number (match-string 1 (buffer-name buf))) nums)))
    (setq nums (sort (cl-delete-duplicates nums :test #'=) #'<))
    (number-to-string
     (catch 'next
       (let ((i 1))
         (dolist (n nums)
           (when (/= n i) (throw 'next i))
           (setq i (1+ n)))
         i)))))

;;; Shared implementation functions

(defun vtermux--format-buffer-name (bufname directory &optional label)
  "Format a vtermux buffer name.
BUFNAME is the base buffer name.  DIRECTORY is the working directory.
LABEL is an optional disambiguating string."
  (let ((root (abbreviate-file-name directory)))
    (if label
        (format "*%s - %s (%s)*" bufname root label)
      (format "*%s - %s*" bufname root))))

(defun vtermux--buffers (bufname buf-list &optional directory)
  "Return live vtermux buffers for BUFNAME in BUF-LIST matching DIRECTORY.
When DIRECTORY is nil, return all live buffers."
  (if (null directory)
      (cl-remove-if-not #'buffer-live-p buf-list)
    (let ((prefix (format "*%s - %s" bufname (abbreviate-file-name directory))))
      (cl-remove-if-not
       (lambda (buf)
         (and (buffer-live-p buf)
              (string-prefix-p prefix (buffer-name buf))))
       buf-list))))

(defun vtermux--create-buffer (prog bufname args buf-list-sym directory &optional label)
  "Create a vterm buffer running PROG with ARGS at DIRECTORY.
BUFNAME is the base buffer name.  BUF-LIST-SYM is the symbol whose
value holds the buffer list for this application.
LABEL is an optional disambiguating string."
  (let* ((name (vtermux--format-buffer-name bufname directory label))
         (default-directory directory)
         (vterm-shell (cond
                        ((null args) prog)
                        ((stringp args) (format "%s %s" prog args))
                        ((listp args) (combine-and-quote-strings (cons prog args)))))
         (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (vterm-mode)
      (when vtermux-kill-buffer-on-exit
        (when-let* ((proc (get-buffer-process (current-buffer))))
          (set-process-sentinel
           proc
           (lambda (proc change)
             (when (string-match "\\(finished\\|exited\\)" change)
               (kill-buffer (process-buffer proc)))))))
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (set buf-list-sym
                       (delq (current-buffer) (symbol-value buf-list-sym))))
                nil t))
    (set buf-list-sym (nconc (symbol-value buf-list-sym) (list buffer)))
    buffer))

(defun vtermux--launch (prog bufname args buf-list-sym directory)
  "Launch or reuse a PROG instance at DIRECTORY.
If instances exist, prompts for a label and creates a new one."
  (let* ((buf-list (symbol-value buf-list-sym))
         (existing (vtermux--buffers bufname buf-list directory)))
    (if existing
        (let* ((default-label (vtermux--next-label existing))
               (label (read-string (format "Label for new %s instance: " prog)
                                   nil nil default-label)))
          (switch-to-buffer
           (vtermux--create-buffer prog bufname args buf-list-sym directory label)))
      (switch-to-buffer
       (vtermux--create-buffer prog bufname args buf-list-sym directory)))))

(defun vtermux--launch-new (prog bufname args buf-list-sym directory)
  "Create a new PROG instance at DIRECTORY, always prompting for a label."
  (let* ((buf-list (symbol-value buf-list-sym))
         (existing (vtermux--buffers bufname buf-list directory))
         (default-label (vtermux--next-label existing))
         (label (read-string (format "Label for new %s instance: " prog)
                             nil nil default-label)))
    (switch-to-buffer
     (vtermux--create-buffer prog bufname args buf-list-sym directory label))))

(defun vtermux--select (prog buf-list-sym)
  "Select a PROG buffer with completing-read."
  (let ((buffers (cl-remove-if-not #'buffer-live-p (symbol-value buf-list-sym))))
    (if buffers
        (switch-to-buffer
         (completing-read (format "%s instance: " prog)
                          (mapcar #'buffer-name buffers) nil t))
      (message (format "No %s instances running." prog)))))

(defun vtermux--cycle (prog bufname args buf-list-sym directory direction offset)
  "Switch DIRECTION by OFFSET in the PROG buffer list scoped to DIRECTORY.
When no buffers exist in DIRECTORY, delegate to `vtermux--launch'."
  (let* ((buf-list (symbol-value buf-list-sym))
         (buffers (vtermux--buffers bufname buf-list directory)))
    (if (null buffers)
        (vtermux--launch prog bufname args buf-list-sym directory)
      (let* ((len (length buffers))
             (idx (cl-position (current-buffer) buffers))
             (target (mod (if (eq direction 'next)
                              (+ (or idx -1) offset)
                            (- (or idx 1) offset))
                          len)))
        (switch-to-buffer (nth target buffers))))))

(defun vtermux--next-key (name)
  "Return a one or two character default dispatch key for NAME."
  (let* ((used (delq nil (mapcar (lambda (e) (nth 2 (cdr e))) vtermux--registry)))
         (str (symbol-name name))
         (len (length str))
         key)
    ;; First pass: single characters
    (catch 'found
      (dotimes (i len)
        (let ((ch (string (aref str i))))
          (unless (member ch used)
            (setq key ch)
            (throw 'found nil)))))
    ;; Second pass: two-letter combos
    (unless key
      (catch 'found
        (dotimes (i len)
          (dotimes (j len)
            (when (/= i j)
              (let ((combo (concat (string (aref str i)) (string (aref str j)))))
                (unless (member combo used)
                  (setq key combo)
                  (throw 'found nil))))))))
    (or key (string (aref str 0)))))

;;;###autoload
(defmacro vtermux-define (name &rest args)
  "Define a vtermux application NAME.
NAME is a symbol used as the prefix for all generated functions.

Generated commands:
  NAME        – launch an instance (prompts for label when one exists)
  NAME-new    – always create a new instance with label prompt
  NAME-select – pick a live instance via completing-read
  NAME-next   – cycle forward through current instances
  NAME-prev   – cycle backward through current instances

Keyword arguments:
  :program STRING      - executable to run (default: (symbol-name NAME))
  :buffer-name STRING  - base buffer name (default: (symbol-name NAME))
  :args STRING         - command line arguments string (default: nil)
  :directory SYMBOL    - directory resolution method: `:project',
                         `:buffer', or `:prompt'
                         (default: `vtermux-command-directory')
  :key CHAR-OR-STRING  - dispatch shortcut for `vtermux-run'
                         (default: first unused letter or letter pair
                         from NAME)

`vtermux-run' dispatches to apps by prefix-matching their `:key'.
Type characters to narrow; `?' shows help, `DEL' backs up.

Directory resolution:
  With \\[universal-argument], always prompted for a directory.
  Otherwise uses the per-definition `:directory' value or falls back
  to `vtermux-command-directory'.  On error, prompts the user."
  (declare (indent 1))
  (let* ((prog (or (plist-get args :program) (symbol-name name)))
         (bufname (or (plist-get args :buffer-name) (symbol-name name)))
         (cmd-args (plist-get args :args))
         (key-val (let ((v (plist-get args :key)))
                    (cond ((characterp v) (string v))
                          ((stringp v) v)
                          (t nil))))
         (prog-var (intern (format "%s-program" name)))
         (bufname-var (intern (format "%s-buffer-name" name)))
         (args-var (intern (format "%s-args" name)))
         (buf-list-var (intern (format "%s-buffer-list" name)))
         (directory-var (intern (format "%s-command-directory" name)))
         (directory-val (if (plist-member args :directory)
                            (plist-get args :directory)
                          'default))
         (fn (intern (symbol-name name)))
         (fn-new (intern (format "%s-new" name)))
         (fn-select (intern (format "%s-select" name)))
         (fn-next (intern (format "%s-next" name)))
         (fn-prev (intern (format "%s-prev" name))))
    `(progn
       (defcustom ,prog-var ,prog
         ,(format "Program to run for `%s'." name)
         :type 'string
         :group 'vtermux)
       (defcustom ,bufname-var ,bufname
         ,(format "Base buffer name for `%s'." name)
         :type 'string
         :group 'vtermux)
       (defcustom ,args-var ,cmd-args
          ,(format "Command line arguments for `%s'." name)
          :type '(choice (const :tag "None" nil) string (repeat :tag "List of arguments" string))
          :group 'vtermux)
       (defvar ,buf-list-var nil
         ,(format "List of `%s' vterm buffers." name))
       (defvar ,directory-var ',directory-val
         ,(format "Directory method for `%s' (`:project', `:buffer', `:prompt', or default)." name))

       ;;;###autoload
         (defun ,fn (&optional arg)
           ,(concat
             (format "Launch %s.\n\n" prog)
             "With \\[universal-argument], prompt for a directory.
        Otherwise uses the configured directory method.")
          (interactive "P")
          (vtermux--launch ,prog-var ,bufname-var ,args-var
                           ',buf-list-var
                           (vtermux--command-directory ,directory-var arg)))

       ;;;###autoload
       (defun ,fn-new (&optional arg)
         ,(format "Create a new %s instance." prog)
         (interactive "P")
         (vtermux--launch-new ,prog-var ,bufname-var ,args-var
                              ',buf-list-var
                              (vtermux--command-directory ,directory-var arg)))

       ;;;###autoload
       (defun ,fn-select ()
         ,(format "Select a %s buffer with completing-read." prog)
         (interactive)
         (vtermux--select ,prog-var ',buf-list-var))

       ;;;###autoload
       (defun ,fn-next (&optional offset)
         ,(format "Switch to the next %s buffer, skipping OFFSET buffers." prog)
         (interactive "P")
         (vtermux--cycle ,prog-var ,bufname-var ,args-var
                         ',buf-list-var
                         (vtermux--command-directory ,directory-var)
                         'next (or offset 1)))

       ;;;###autoload
       (defun ,fn-prev (&optional offset)
         ,(format "Switch to the previous %s buffer, skipping OFFSET buffers." prog)
         (interactive "P")
         (vtermux--cycle ,prog-var ,bufname-var ,args-var
                         ',buf-list-var
                         (vtermux--command-directory ,directory-var)
                         'prev (or offset 1)))

       (let* ((cell (assq ',name vtermux--registry))
               (key ,(if (plist-member args :key)
                         key-val
                       `(if cell
                            (nth 2 (cdr cell))
                          (vtermux--next-key ',name)))))
          (if cell
              (setcdr cell (list ',prog-var ',fn key))
            (push (cons ',name (list ',prog-var ',fn key)) vtermux--registry)))
        ',name)))

(defvar vtermux--registry nil
  "Alist of (NAME . (PROGRAM-VAR FN KEY)) for all defined vtermux applications.
PROGRAM-VAR is the symbol holding the program name.  FN is the
generated interactive command symbol.  KEY is the dispatch prefix
string for `vtermux-run', or nil.")

;;;###autoload
(defun vtermux-run (&optional arg)
  "Launch a vtermux application by single-character dispatch.

Press a single key matching an app's `:key' to launch it immediately.
Press `?' to show all available apps in a help buffer.

With \\[universal-argument], prompt for a directory.
Otherwise uses the configured directory method."
  (interactive "P")
  (let* ((app-keys
          (delq nil
                (mapcar (lambda (e)
                          (when-let* ((k (nth 2 (cdr e))))
                            (cons (aref k 0) (car e))))
                        vtermux--registry)))
         (keys (sort (mapcar #'car app-keys) #'<))
         (prompt (format "vtermux [%s]: "
                         (mapconcat (lambda (ak) (format "%c:%s" (car ak) (cdr ak)))
                                    (sort (copy-sequence app-keys)
                                          (lambda (a b) (< (car a) (car b))))
                                    " "))))
    (if (null keys)
        (user-error "No vtermux apps have a :key set")
      (let ((ch (read-char-choice prompt keys)))
        (let* ((app (cdr (assq ch app-keys)))
               (entry (assq app vtermux--registry))
               (directory (vtermux--command-directory nil arg)))
          (vtermux--launch (symbol-value (cadr entry))
                           (symbol-value (intern (format "%s-buffer-name" app)))
                           (symbol-value (intern (format "%s-args" app)))
                           (intern (format "%s-buffer-list" app))
                            directory))))))

(provide 'vtermux)
;;; vtermux.el ends here

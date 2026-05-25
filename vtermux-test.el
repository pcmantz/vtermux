;;; vtermux-test.el --- Tests for vtermux.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; Stub the entire vterm package so vtermux.el can be loaded without it.
(defgroup vterm nil "Stub vterm group for testing." :group 'emacs)
(defvar vterm-shell nil "Stub value set by vtermux--create-buffer.")
(provide 'vterm)

;; Mock vterm-mode so tests don't need the native vterm-module.
(unless (fboundp 'vterm-mode)
  (define-derived-mode vterm-mode fundamental-mode "Vterm"
    "Mock vterm mode for testing."))

(require 'vtermux)

;; Test globals captured by mocked functions
(defvar vtermux-test--switched-buffer nil
  "Buffer or name passed to `switch-to-buffer' during a test.")
(defvar vtermux-test--vterm-shell nil
  "Value of `vterm-shell' captured when vterm-mode runs.")
(defvar vtermux-test--read-string-result nil
  "Value returned by mocked `read-string'.")
(defvar vtermux-test--completing-read-result nil
  "Value returned by mocked `completing-read'.")
(defvar vtermux-test--message-args nil
  "Args passed to `message' during a test.")
(defvar vtermux-test--read-directory-name-result nil
  "Value returned by mocked `read-directory-name'.")
(defvar vtermux-test--read-char-choice-result nil
  "Value returned by mocked `read-char-choice'.")

;; ─── Helpers ─────────────────────────────────────────────────────────

(defun vtermux-test--make-buffer (name)
  "Return a new live buffer with exact NAME; kill any existing first."
  (let ((old (get-buffer name)))
    (when old (kill-buffer old)))
  (generate-new-buffer name))

(defun vtermux-test--with-mocks (fn)
  "Call FN with common functions mocked and globals reset."
  (let ((vtermux-test--switched-buffer nil)
        (vtermux-test--vterm-shell nil)
        (vtermux-test--read-string-result "test-label")
        (vtermux-test--completing-read-result "buf-1")
        (vtermux-test--message-args nil)
        (vtermux-test--read-directory-name-result "/tmp/mocked-dir")
        (vtermux-test--read-char-choice-result ?b))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buf-or-name &rest _)
                 (setq vtermux-test--switched-buffer buf-or-name)
                 (if (bufferp buf-or-name) buf-or-name (get-buffer buf-or-name))))
              ((symbol-function 'read-string)
               (lambda (&rest _) vtermux-test--read-string-result))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (or vtermux-test--completing-read-result
                     (caar coll))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq vtermux-test--message-args (cons fmt args))))
               ((symbol-function 'read-directory-name)
                (lambda (&rest _) vtermux-test--read-directory-name-result))
               ((symbol-function 'read-char-choice)
                (lambda (_prompt _chars)
                  vtermux-test--read-char-choice-result)))
      (funcall fn))))

(defun vtermux-test--capture-vterm-shell (&rest _)
  "Set `vtermux-test--vterm-shell' from the dynamic value of `vterm-shell'."
  (setq vtermux-test--vterm-shell vterm-shell))

;; ─── vtermux--format-buffer-name ────────────────────────────────────

(ert-deftest vtermux-test--format-buffer-name-without-label ()
  (should (equal (vtermux--format-buffer-name "btop" "/tmp/test-dir")
                 "*btop - /tmp/test-dir*"))
  (should (equal (vtermux--format-buffer-name "opencode" "/var/log")
                 "*opencode - /var/log*")))

(ert-deftest vtermux-test--format-buffer-name-with-label ()
  (should (equal (vtermux--format-buffer-name "btop" "/tmp/test-dir" "1")
                 "*btop - /tmp/test-dir (1)*"))
  (should (equal (vtermux--format-buffer-name "btop" "/tmp/test-dir" "custom")
                 "*btop - /tmp/test-dir (custom)*")))

;; ─── vtermux--next-label ────────────────────────────────────────────

(ert-deftest vtermux-test--next-label-empty ()
  (should (equal (vtermux--next-label nil) "1"))
  (should (equal (vtermux--next-label '()) "1")))

(ert-deftest vtermux-test--next-label-no-labels ()
  (let ((buf (generate-new-buffer "*btop - n*")))
    (unwind-protect
        (should (equal (vtermux--next-label (list buf)) "1"))
      (kill-buffer buf))))

(ert-deftest vtermux-test--next-label-gap ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (vtermux-test--make-buffer "*btop - g (1)*") bufs)
          (push (vtermux-test--make-buffer "*btop - g (2)*") bufs)
          (push (vtermux-test--make-buffer "*btop - g (4)*") bufs)
          (should (equal (vtermux--next-label bufs) "3")))
      (mapc #'kill-buffer bufs))))

(ert-deftest vtermux-test--next-label-sequential ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (vtermux-test--make-buffer "*btop - s (1)*") bufs)
          (push (vtermux-test--make-buffer "*btop - s (2)*") bufs)
          (push (vtermux-test--make-buffer "*btop - s (3)*") bufs)
          (should (equal (vtermux--next-label bufs) "4")))
      (mapc #'kill-buffer bufs))))

(ert-deftest vtermux-test--next-label-dead-buffer-filtered ()
  (let* ((live (vtermux-test--make-buffer "*btop - d (2)*"))
         (dead (vtermux-test--make-buffer "*btop - d (1)*")))
    (kill-buffer dead)
    (unwind-protect
        (should (equal (vtermux--next-label (list live dead)) "1"))
      (kill-buffer live))))

(ert-deftest vtermux-test--next-label-duplicates ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (vtermux-test--make-buffer "*btop - dup (1)*") bufs)
          (push (vtermux-test--make-buffer "*btop - dup (1)*") bufs)
          (push (vtermux-test--make-buffer "*btop - dup (3)*") bufs)
          (should (equal (vtermux--next-label bufs) "2")))
      (mapc #'kill-buffer bufs))))

;; ─── vtermux--buffers ───────────────────────────────────────────────

(ert-deftest vtermux-test--buffers-all-live ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (generate-new-buffer "*btop - /tmp/one*") bufs)
          (push (generate-new-buffer "*btop - /tmp/two*") bufs)
          (push (generate-new-buffer "*claude - /tmp*") bufs)
          ;; directory=nil returns ALL live buffers regardless of bufname
          (should (= (length (vtermux--buffers "btop" bufs)) 3)))
      (mapc #'kill-buffer bufs))))

(ert-deftest vtermux-test--buffers-filters-dead ()
  (let* ((live (generate-new-buffer "*btop - /tmp/live*"))
         (dead (generate-new-buffer "*btop - /tmp/dead*")))
    (kill-buffer dead)
    (unwind-protect
        (should (= (length (vtermux--buffers "btop" (list live dead))) 1))
      (kill-buffer live))))

(ert-deftest vtermux-test--buffers-scoped-by-directory ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (generate-new-buffer "*btop - /tmp/one*") bufs)
          (push (generate-new-buffer "*btop - /tmp/two*") bufs)
          (should (= (length (vtermux--buffers "btop" bufs "/tmp/one")) 1))
          (should (= (length (vtermux--buffers "btop" bufs "/tmp/three")) 0)))
      (mapc #'kill-buffer bufs))))

(ert-deftest vtermux-test--buffers-directory-nil ()
  (let (bufs)
    (unwind-protect
        (progn
          (push (generate-new-buffer "*btop - /tmp/a*") bufs)
          (push (generate-new-buffer "*btop - /tmp/b*") bufs)
          (push (generate-new-buffer "*claude - /tmp*") bufs)
          ;; directory=nil returns ALL live buffers
          (should (= (length (vtermux--buffers "btop" bufs nil)) 3)))
      (mapc #'kill-buffer bufs))))

;; ─── vtermux--create-buffer ─────────────────────────────────────────

(ert-deftest vtermux-test--create-buffer-name ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil)
         buf)
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
      (setq buf (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp")))
    (unwind-protect
        (should (equal (buffer-name buf) "*btop - /tmp*"))
      (kill-buffer buf))))

(ert-deftest vtermux-test--create-buffer-name-with-label ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil)
         buf)
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
      (setq buf (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp" "1")))
    (unwind-protect
        (should (equal (buffer-name buf) "*btop - /tmp (1)*"))
      (kill-buffer buf))))

(ert-deftest vtermux-test--create-buffer-appends-to-list ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil)
         buf)
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
      (setq buf (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp")))
    (unwind-protect
        (should (equal (symbol-value buf-list-sym) (list buf)))
      (kill-buffer buf))))

(ert-deftest vtermux-test--create-buffer-kill-buffer-hook ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil)
         buf)
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
      (setq buf (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp")))
    (should (buffer-local-value 'kill-buffer-hook buf))
    (kill-buffer buf)
    (should (null (symbol-value buf-list-sym)))))

(ert-deftest vtermux-test--create-buffer-vterm-shell-nil ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil))
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode)
               (lambda ()
                 (setq vtermux-test--vterm-shell vterm-shell))))
      (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp")
      (should (equal vtermux-test--vterm-shell "btop")))))

(ert-deftest vtermux-test--create-buffer-vterm-shell-string ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil))
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode)
               (lambda ()
                 (setq vtermux-test--vterm-shell vterm-shell))))
      (vtermux--create-buffer "myapp" "myapp" "-x -v" buf-list-sym "/tmp")
      (should (equal vtermux-test--vterm-shell "myapp -x -v")))))

(ert-deftest vtermux-test--create-buffer-vterm-shell-list ()
  (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
         (vtermux-kill-buffer-on-exit nil))
    (set buf-list-sym nil)
    (cl-letf (((symbol-function 'vterm-mode)
               (lambda ()
                 (setq vtermux-test--vterm-shell vterm-shell))))
      (vtermux--create-buffer "myapp" "myapp" '("-x" "-v" "--name" "foo bar")
                              buf-list-sym "/tmp")
      (should (equal vtermux-test--vterm-shell
                     "myapp -x -v --name \"foo bar\"")))))

;; ─── vtermux--command-directory ────────────────────────────────────

(ert-deftest vtermux-test--command-directory-buffer ()
  (should (equal (let ((default-directory "/tmp/test-dir"))
                   (vtermux--command-directory :buffer))
                 "/tmp/test-dir")))

(ert-deftest vtermux-test--command-directory-project ()
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional _) (cons 'vc "/tmp/proj-root")))
            ((symbol-function 'project-root)
             (lambda (proj) (cdr proj))))
    (should (equal (vtermux--command-directory :project)
                   "/tmp/proj-root"))))

(ert-deftest vtermux-test--command-directory-prompt ()
  (let ((vtermux-test--read-directory-name-result "/tmp/picked"))
    (cl-letf (((symbol-function 'read-directory-name)
               (lambda (&rest _) vtermux-test--read-directory-name-result)))
      (should (equal (vtermux--command-directory :prompt)
                     "/tmp/picked")))))

(ert-deftest vtermux-test--command-directory-prompt-flag ()
  (let ((vtermux-test--read-directory-name-result "/tmp/from-flag"))
    (cl-letf (((symbol-function 'read-directory-name)
               (lambda (&rest _) vtermux-test--read-directory-name-result)))
      (should (equal (vtermux--command-directory :buffer t)
                     "/tmp/from-flag")))))

(ert-deftest vtermux-test--command-directory-default-method ()
  (let ((default-directory "/tmp/the-default"))
    (should (equal (vtermux--command-directory nil)
                   "/tmp/the-default"))))

;; ─── vtermux--launch ────────────────────────────────────────────────

(ert-deftest vtermux-test--launch-first-instance ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            result)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq result (vtermux--launch "btop" "btop" nil buf-list-sym "/tmp/launch-0")))
       (unwind-protect
           (progn
             (should (buffer-live-p result))
             (should (equal (buffer-name result) "*btop - /tmp/launch-0*"))
             (should (equal vtermux-test--switched-buffer result)))
         (kill-buffer result))))))

(ert-deftest vtermux-test--launch-second-instance ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            first second)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq first (vtermux--launch "btop" "btop" nil buf-list-sym "/tmp"))
         (setq vtermux-test--read-string-result "my-label")
         (setq second (vtermux--launch "btop" "btop" nil buf-list-sym "/tmp")))
       (unwind-protect
           (progn
             (should (buffer-live-p second))
             (should (equal (buffer-name second)
                            "*btop - /tmp (my-label)*"))
             (should (equal vtermux-test--switched-buffer second)))
         (mapc #'kill-buffer (list first second)))))))

;; ─── vtermux--launch-new ────────────────────────────────────────────

(ert-deftest vtermux-test--launch-new-always-prompts ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            result)
       (set buf-list-sym nil)
       (setq vtermux-test--read-string-result "my-new")
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq result (vtermux--launch-new "btop" "btop" nil buf-list-sym "/tmp")))
       (unwind-protect
           (should (equal (buffer-name result) "*btop - /tmp (my-new)*"))
         (kill-buffer result))))))

;; ─── vtermux--select ────────────────────────────────────────────────

(ert-deftest vtermux-test--select-with-buffers ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            buf)
       (set buf-list-sym nil)
       (setq buf (generate-new-buffer "*btop - /tmp*"))
       (set buf-list-sym (list buf))
       (setq vtermux-test--completing-read-result "*btop - /tmp*")
       (vtermux--select "btop" buf-list-sym)
       (should (equal vtermux-test--switched-buffer "*btop - /tmp*"))))))

(ert-deftest vtermux-test--select-without-buffers ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs")))
       (set buf-list-sym nil)
       (vtermux--select "btop" buf-list-sym)
       (should (equal vtermux-test--message-args
                      '("No btop instances running.")))))))

;; ─── vtermux--cycle ─────────────────────────────────────────────────

(ert-deftest vtermux-test--cycle-no-buffers-launches ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            result)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq result (vtermux--cycle "btop" "btop" nil buf-list-sym "/tmp/cycle-0" 'next 1)))
       (unwind-protect
           (should (equal (buffer-name result) "*btop - /tmp/cycle-0*"))
         (kill-buffer result))))))

(ert-deftest vtermux-test--cycle-single-buffer-stays ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            buf)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq buf (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp"))
         (with-current-buffer buf
           (vtermux--cycle "btop" "btop" nil buf-list-sym "/tmp" 'next 1)))
       (should (equal vtermux-test--switched-buffer buf))
       (kill-buffer buf)))))

(ert-deftest vtermux-test--cycle-two-buffers-forward ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            buf-a buf-b)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq buf-a (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp"))
         (setq buf-b (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp" "1"))
         (with-current-buffer buf-a
           (vtermux--cycle "btop" "btop" nil buf-list-sym "/tmp" 'next 1)))
       (unwind-protect
           (should (eq vtermux-test--switched-buffer buf-b))
         (mapc #'kill-buffer (list buf-a buf-b)))))))

(ert-deftest vtermux-test--cycle-current-not-in-list ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            outside buf-a buf-b)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq outside (generate-new-buffer "*scratch*"))
         (setq buf-a (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp"))
         (setq buf-b (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp" "1"))
         (with-current-buffer outside
           (vtermux--cycle "btop" "btop" nil buf-list-sym "/tmp" 'next 1)))
       (unwind-protect
           (should (eq vtermux-test--switched-buffer buf-a))
         (mapc #'kill-buffer (list outside buf-a buf-b)))))))

(ert-deftest vtermux-test--cycle-with-offset ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((buf-list-sym (make-symbol "vtermux-test-bufs"))
            (vtermux-kill-buffer-on-exit nil)
            buf-a buf-b buf-c)
       (set buf-list-sym nil)
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (setq buf-a (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp"))
         (setq buf-b (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp" "1"))
         (setq buf-c (vtermux--create-buffer "btop" "btop" nil buf-list-sym "/tmp" "2"))
         (with-current-buffer buf-a
           (vtermux--cycle "btop" "btop" nil buf-list-sym "/tmp" 'next 2)))
       (unwind-protect
           (should (eq vtermux-test--switched-buffer buf-c))
         (mapc #'kill-buffer (list buf-a buf-b buf-c)))))))

;; ─── vtermux-define macro ───────────────────────────────────────────

(ert-deftest vtermux-test--define-minimal ()
  (let ((vtermux--registry nil))
    (eval (macroexpand '(vtermux-define testapp)))
    (should (boundp 'testapp-program))
    (should (equal testapp-program "testapp"))
    (should (boundp 'testapp-buffer-name))
    (should (equal testapp-buffer-name "testapp"))
    (should (boundp 'testapp-args))
    (should (null testapp-args))
    (should (boundp 'testapp-buffer-list))
    (should (null testapp-buffer-list))
    (should (boundp 'testapp-command-directory))
    (should (eq testapp-command-directory 'default))
    (should (fboundp 'testapp))
    (should (fboundp 'testapp-new))
    (should (fboundp 'testapp-select))
    (should (fboundp 'testapp-next))
    (should (fboundp 'testapp-prev))
    (let ((entry (cdr (assq 'testapp vtermux--registry))))
      (should (equal (car entry) 'testapp-program))
      (should (eq (nth 1 entry) 'testapp))
      (should (equal (nth 2 entry) "t")))))

(ert-deftest vtermux-test--define-all-keywords ()
  (let ((vtermux--registry nil))
    (eval (macroexpand '(vtermux-define myapp
                          :program "/usr/bin/myapp"
                          :buffer-name "MyApp"
                          :args "--verbose"
                          :directory :buffer
                          :key ?m)))
    (should (equal myapp-program "/usr/bin/myapp"))
    (should (equal myapp-buffer-name "MyApp"))
    (should (equal myapp-args "--verbose"))
    (should (eq myapp-command-directory :buffer))
    (let ((entry (cdr (assq 'myapp vtermux--registry))))
      (should (equal (car entry) 'myapp-program))
      (should (eq (nth 1 entry) 'myapp))
      (should (equal (nth 2 entry) "m")))))

(ert-deftest vtermux-test--define-registry-existing ()
  (let ((vtermux--registry '((oldapp . (oldapp-program oldapp "o")))))
    (eval (macroexpand '(vtermux-define newapp)))
    (let ((new-entry (cdr (assq 'newapp vtermux--registry)))
          (old-entry (cdr (assq 'oldapp vtermux--registry))))
      (should (equal (car new-entry) 'newapp-program))
      (should (eq (nth 1 new-entry) 'newapp))
      (should (equal (nth 2 new-entry) "n"))
      (should (eq (car old-entry) 'oldapp-program))
      (should (eq (nth 1 old-entry) 'oldapp))
      (should (equal (nth 2 old-entry) "o")))))

;; ─── vtermux--next-key ────────────────────────────────────────────

(ert-deftest vtermux-test--next-key-first-letter ()
  (let ((vtermux--registry nil))
    (should (equal (vtermux--next-key 'btop) "b"))))

(ert-deftest vtermux-test--next-key-second-letter ()
  (let ((vtermux--registry '((btop . (btop-program btop "b")))))
    (should (equal (vtermux--next-key 'bash) "a"))))

(ert-deftest vtermux-test--next-key-all-singles-used ()
  (let ((vtermux--registry '((a . (a-program a "b"))
                             (b . (b-program b "a"))
                             (c . (c-program c "s"))
                             (d . (d-program d "h")))))
    (should (equal (vtermux--next-key 'bash) "ba"))))

(ert-deftest vtermux-test--next-key-partial-collision ()
  (let ((vtermux--registry '((btop . (btop-program btop "b"))
                             (xapp . (xapp-program xapp "a")))))
    (should (equal (vtermux--next-key 'btop) "t"))))

(ert-deftest vtermux-test--next-key-two-letter ()
  (let ((vtermux--registry '((a . (a-program a "a"))
                             (b . (b-program b "b")))))
    (should (equal (vtermux--next-key 'ab) "ab"))))

;; ─── vtermux-run ────────────────────────────────────────────────────

(ert-deftest vtermux-test--run-picks-from-registry ()
  (vtermux-test--with-mocks
   (lambda ()
     (let* ((vtermux--registry nil)
            (vtermux-command-directory :buffer)
            (vtermux-kill-buffer-on-exit nil))
       (eval (macroexpand '(vtermux-define btop :key ?b)))
       (setq vtermux-test--completing-read-result "btop")
       (cl-letf (((symbol-function 'vterm-mode) #'vtermux-test--capture-vterm-shell))
         (vtermux-run))
       (unwind-protect
           (progn
             (should (bufferp vtermux-test--switched-buffer))
             (should (string-prefix-p "*btop - "
                                      (buffer-name vtermux-test--switched-buffer))))
         (when (bufferp vtermux-test--switched-buffer)
           (kill-buffer vtermux-test--switched-buffer)))))))

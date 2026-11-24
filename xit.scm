(require-builtin helix/core/keymaps as helix.keymaps.)

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require "helix/ext.scm")
(require "helix/keymaps.scm")
(require "helix/configuration.scm")
(require-builtin helix/core/text as text.)
(require (prefix-in helix. "helix/commands.scm"))
(require "notify/notify.scm")

(provide Git
         git
         xit
         git-stage
         git-unstage
         git-stage-selection
         git-unstage-selection
         git-toggle-stage
         git-stage-all
         git-unstage-all
         git-discard
         git-open
         git-diff
         git-resolve-ours
         git-resolve-theirs
         git-commit
         git-commit-amend
         git-commit-finish
         git-commit-abort
         git-commit-msg
         git-push
         git-pull
         git-refresh
         git-close
         git-help
         git-save
         xit-info
         xit-error
         XIT-BUFFER-NAME
         XIT-COMMIT-BUFFER-NAME
         XIT-DIFF-BUFFER-NAME
         GIT-BUFFER-NAME
         GIT-COMMIT-BUFFER-NAME
         GIT-DIFF-BUFFER-NAME
         XIT-KEYMAPS
         XIT-COMMIT-KEYMAPS
         XIT-DIFF-KEYMAPS
         xit-install-buffer-keymap!
         ;; Aliases with xit- prefix
         xit-stage
         xit-unstage
         xit-stage-selection
         xit-unstage-selection
         xit-toggle-stage
         xit-stage-all
         xit-unstage-all
         xit-discard
         xit-open
         xit-diff
         xit-resolve-ours
         xit-resolve-theirs
         xit-commit
         xit-commit-amend
         xit-commit-finish
         xit-commit-abort
         xit-commit-msg
         xit-push
         xit-pull
         xit-refresh
         xit-close
         xit-help
         xit-save)

;; Buffer names
(define XIT-BUFFER-NAME "*git*")
(define XIT-COMMIT-BUFFER-NAME "*git-commit*")
(define XIT-DIFF-BUFFER-NAME "*git-diff*")

(define GIT-BUFFER-NAME XIT-BUFFER-NAME)
(define GIT-COMMIT-BUFFER-NAME XIT-COMMIT-BUFFER-NAME)
(define GIT-DIFF-BUFFER-NAME XIT-DIFF-BUFFER-NAME)

;; Install a buffer-local keymap that inherits the current global keys. Called
;; when a xit buffer is created so the required keymaps work without any setup
;; in init.scm, while preserving keys like <space>g and normal navigation.
(define (xit-install-buffer-keymap! label bindings)
  (set-global-buffer-or-extension-keymap
    (hash label (merge-keybindings (deep-copy-global-keybindings) bindings)))
  void)

;; Internal state
(define *xit-dir* #false)
(define *xit-doc-id* #false)
(define *xit-commit-doc-id* #false)
(define *xit-diff-doc-id* #false)
(define *xit-original-sections* #false)
(define *xit-show-help* #false)
(define *xit-commit-amend?* #false)
(define *xit-commit-path* #false)
(define *xit-commit-finishing?* #false)
(define *xit-save-hook-registered?* #false)

;; Notifications via notify.hx
(define (xit-info msg)
  (notify msg #:title "xit.hx"))

(define (xit-error msg)
  (notify msg #:severity 'error #:title "xit.hx"))

;; Check whether a language id is configured in Helix.
(define (xit-language-configured? language)
  (with-handler (lambda (_) #f)
    (if (get-language-config language) #t #f)))

;; Apply a Helix language automatically to the focused buffer. If the language
;; is not configured, use the optional fallback (e.g. git-diff -> diff).
;; A missing grammar should never break the git UI.
(define (xit-set-buffer-language! language [fallback #f])
  (let ([chosen (if (xit-language-configured? language)
                    language
                    (or fallback language))])
    (with-handler (lambda (_) void)
      (helix.set-language chosen))
    ;; Return void so Helix does not print the result in the status line.
    void))

;; =============================================================================
;; Core Git Operations Engine
;; =============================================================================

(define (path-join base name)
  (string-append base (path-separator) name))

;; Execute a git command in the given directory
(define (git-exec dir args)
  (let ([proc (~> (command "git" (cons "-C" (cons dir args)))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (if (Ok? proc)
        (let* ([child (Ok->value proc)]
               [out-p (child-stdout child)]
               [err-p (child-stderr child)]
               [out (if out-p (read-port-to-string out-p) "")]
               [err (if err-p (read-port-to-string err-p) "")])
          (hash 'ok (string=? (trim err) "")
                'stdout out
                'stderr err))
        (hash 'ok #false
              'stdout ""
              'stderr "Failed to spawn git process"))))

;; Check if a directory is inside a git working tree
(define (git-repo? dir)
  (let ([res (git-exec dir '("rev-parse" "--is-inside-work-tree"))])
    (and (hash-ref res 'ok)
         (string=? (trim (hash-ref res 'stdout)) "true"))))

;; Get the toplevel root directory of the git repo
(define (git-repo-root dir)
  (let ([res (git-exec dir '("rev-parse" "--show-toplevel"))])
    (if (hash-ref res 'ok)
        (let ([out (trim (hash-ref res 'stdout))])
          (if (string=? out "") #false out))
        #false)))

;; Check if the repository has at least one commit
(define (git-has-commits? dir)
  (let ([res (git-exec dir '("rev-parse" "--verify" "HEAD"))])
    (hash-ref res 'ok)))

;; Parse the "## branch..." line from git status --porcelain -b
(define (parse-branch-header line)
  (let ([raw (trim (substring line 2 (string-length line)))])
    (cond
      [(starts-with? raw "No commits yet on ")
       (hash 'branch (substring raw 18 (string-length raw))
             'status "No commits yet"
             'upstream #false
             'ahead 0
             'behind 0)]
      [(starts-with? raw "Initial commit on ")
       (hash 'branch (substring raw 18 (string-length raw))
             'status "No commits yet"
             'upstream #false
             'ahead 0
             'behind 0)]
      [(starts-with? raw "HEAD (no branch)")
       (hash 'branch "HEAD (detached)"
             'status "detached"
             'upstream #false
             'ahead 0
             'behind 0)]
      [else
       (let* ([parts (split-many raw " [")]
              [branch-part (list-ref parts 0)]
              [info-part (if (> (length parts) 1) (list-ref parts 1) #false)]
              [dots-parts (split-many branch-part "...")]
              [branch (list-ref dots-parts 0)]
              [upstream (if (> (length dots-parts) 1) (list-ref dots-parts 1) #false)]
              [status-desc
               (cond
                 [(not upstream) "local branch"]
                 [(not info-part) (string-append "tracking " upstream " [up to date]")]
                 [else (string-append "tracking " upstream " [" info-part)])])
         (hash 'branch branch
               'status status-desc
               'upstream upstream
               'ahead 0
               'behind 0))])))

;; Parse git status --porcelain=v1 -uall output into staged, unstaged, untracked, unmerged
(define (parse-porcelain-status output)
  (let* ([lines (filter (lambda (l) (> (string-length l) 0))
                        (split-many output "\n"))]
         [branch-info (hash 'branch "HEAD" 'status "unknown" 'upstream #false 'ahead 0 'behind 0)]
         [staged '()]
         [unstaged '()]
         [untracked '()]
         [unmerged '()])
    (for-each
      (lambda (line)
        (cond
          [(starts-with? line "## ")
           (set! branch-info (parse-branch-header line))]
          [(>= (string-length line) 3)
           (let* ([x (string-ref line 0)]
                  [y (string-ref line 1)]
                  [raw-path (trim (substring line 3 (string-length line)))]
                  [path (if (and (char=? x #\R) (string-contains? raw-path " -> "))
                            (list-ref (split-many raw-path " -> ") 1)
                            raw-path)])
             (cond
               ;; Unmerged / conflicted
               [(or (char=? x #\U) (char=? y #\U)
                    (and (char=? x #\A) (char=? y #\A))
                    (and (char=? x #\D) (char=? y #\D)))
                (set! unmerged (cons (cons (string x y) path) unmerged))]
               ;; Untracked
               [(and (char=? x #\?) (char=? y #\?))
                (set! untracked (cons path untracked))]
               ;; Staged and/or Unstaged
               [else
                (when (member x '(#\M #\A #\D #\R #\C))
                  (set! staged (cons (cons (string x) raw-path) staged)))
                (when (member y '(#\M #\D))
                  (set! unstaged (cons (cons (string y) path) unstaged)))]))]))
      lines)
    (hash 'branch branch-info
          'staged (reverse staged)
          'unstaged (reverse unstaged)
          'untracked (reverse untracked)
          'unmerged (reverse unmerged))))

;; Get head info from git status
(define (git-head-info dir)
  (let ([res (git-exec dir '("status" "--porcelain=v1" "-b"))])
    (if (hash-ref res 'ok)
        (let* ([lines (filter (lambda (l) (> (string-length l) 0))
                              (split-many (hash-ref res 'stdout) "\n"))])
          (if (and (pair? lines) (starts-with? (car lines) "## "))
              (parse-branch-header (car lines))
              (hash 'branch "HEAD" 'status "unknown" 'upstream #false 'ahead 0 'behind 0)))
        (hash 'branch "unknown" 'status "error" 'upstream #false 'ahead 0 'behind 0))))

;; Get all git status entries for a repo
(define (git-status-entries dir)
  (let ([res (git-exec dir '("status" "--porcelain=v1" "-b" "-uall"))])
    (if (hash-ref res 'ok)
        (parse-porcelain-status (hash-ref res 'stdout))
        (hash 'branch (hash 'branch "HEAD" 'status "error" 'upstream #false 'ahead 0 'behind 0)
              'staged '()
              'unstaged '()
              'untracked '()
              'unmerged '()))))

;; Get recent commits (up to count)
(define (git-recent-commits dir [count 5])
  (if (git-has-commits? dir)
      (let ([res (git-exec dir (list "log" (string-append "-n" (number->string count)) "--oneline"))])
        (if (hash-ref res 'ok)
            (let ([lines (filter (lambda (l) (> (string-length l) 0))
                                 (split-many (hash-ref res 'stdout) "\n"))])
              (map (lambda (line)
                     (let* ([trimmed (trim line)]
                            [parts (split-whitespace trimmed)]
                            [c-hash (if (pair? parts) (car parts) "")]
                            [subj (if (pair? parts)
                                      (trim (substring trimmed (string-length c-hash) (string-length trimmed)))
                                      "")])
                       (cons c-hash subj)))
                   lines))
            '()))
      '()))

;; Format the full interactive git status buffer
(define (format-status-buffer repo-dir head-info entries recent-commits show-help?)
  (let* ([branch-str (hash-ref head-info 'branch)]
         [status-str (hash-ref head-info 'status)]
         [unmerged   (hash-ref entries 'unmerged)]
         [unstaged   (hash-ref entries 'unstaged)]
         [staged     (hash-ref entries 'staged)]
         [untracked  (hash-ref entries 'untracked)]
         [out-lines  '()])

    (define (emit! line)
      (set! out-lines (cons line out-lines)))

    ;; Header
    (emit! (string-append "Head:    " branch-str " (" status-str ")"))
    (emit! (string-append "Repo:    " repo-dir))
    (emit! "")

    ;; Help or Keys banner
    (if show-help?
        (begin
          (emit! "Help (press '?' to hide):")
          (emit! "  s        Stage file/section, or every file in selection")
          (emit! "  u        Unstage file/section, or every file in selection")
          (emit! "  v/V/C-j  Select line(s), then s to stage or u to unstage")
          (emit! "  d        Discard unstaged changes / delete untracked file (confirm y)")
          (emit! "  ret      Open file in editor (or show commit diff)")
          (emit! "  D        Show diff in buffer")
          (emit! "  O        Resolve conflict using OURS version")
          (emit! "  T        Resolve conflict using THEIRS version")
          (emit! "  c        Open commit editor; :w writes and commits")
          (emit! "  C        Amend last commit")
          (emit! "  S        Stage all changes")
          (emit! "  U        Unstage all changes")
          (emit! "  P        Git push")
          (emit! "  p        Git pull")
          (emit! "  r        Refresh status")
          (emit! "  :git-save Apply edited buffer to git")
          (emit! "  q        Close git buffer")
          (emit! ""))
        (begin
          (emit! "Keys:    [s] stage  [u] unstage  [d] discard (confirm)  [c] commit  [D] diff  [v] select  [?] help")
          (emit! "")))

    ;; Unmerged (Conflicts)
    (when (not (null? unmerged))
      (emit! (string-append "Unmerged (" (number->string (length unmerged)) ")"))
      (for-each
        (lambda (item)
          (emit! (string-append "  " (car item) "  " (cdr item))))
        unmerged)
      (emit! ""))

    ;; Unstaged
    (when (not (null? unstaged))
      (emit! (string-append "Unstaged (" (number->string (length unstaged)) ")"))
      (for-each
        (lambda (item)
          (emit! (string-append "  " (car item) "  " (cdr item))))
        unstaged)
      (emit! ""))

    ;; Staged
    (when (not (null? staged))
      (emit! (string-append "Staged (" (number->string (length staged)) ")"))
      (for-each
        (lambda (item)
          (emit! (string-append "  " (car item) "  " (cdr item))))
        staged)
      (emit! ""))

    ;; Untracked
    (when (not (null? untracked))
      (emit! (string-append "Untracked (" (number->string (length untracked)) ")"))
      (for-each
        (lambda (item)
          (emit! (string-append "  ?  " item)))
        untracked)
      (emit! ""))

    ;; If working tree clean
    (when (and (null? unmerged) (null? unstaged) (null? staged) (null? untracked))
      (emit! "Working tree clean. Nothing to commit.")
      (emit! ""))

    ;; Recent commits
    (when (not (null? recent-commits))
      (emit! (string-append "Recent Commits (" (number->string (length recent-commits)) ")"))
      (for-each
        (lambda (c)
          (emit! (string-append "  " (car c) "  " (cdr c))))
        recent-commits)
      (emit! ""))

    (string-join (reverse out-lines) "\n")))

;; Parse line target from buffer lines and 0-indexed line number
(define (parse-line-target lines line-n)
  (if (or (< line-n 0) (>= line-n (length lines)))
      (hash 'type 'none)
      (let ([line (list-ref lines line-n)])
        (cond
          [(starts-with? line "Unmerged (")
           (hash 'type 'section-header 'section 'unmerged)]
          [(starts-with? line "Unstaged (")
           (hash 'type 'section-header 'section 'unstaged)]
          [(starts-with? line "Staged (")
           (hash 'type 'section-header 'section 'staged)]
          [(starts-with? line "Untracked (")
           (hash 'type 'section-header 'section 'untracked)]
          [(starts-with? line "Recent Commits (")
           (hash 'type 'section-header 'section 'recent-commits)]
          [(starts-with? line "  ")
           (let loop ([idx (- line-n 1)])
             (if (< idx 0)
                 (hash 'type 'none)
                 (let ([prev-line (list-ref lines idx)])
                   (cond
                     [(starts-with? prev-line "Unmerged (")
                      (let* ([trimmed (trim line)]
                             [parts (split-whitespace trimmed)]
                             [status (car parts)]
                             [path (trim (substring trimmed (string-length status) (string-length trimmed)))])
                        (hash 'type 'entry 'section 'unmerged 'status status 'path path))]
                     [(starts-with? prev-line "Unstaged (")
                      (let* ([trimmed (trim line)]
                             [parts (split-whitespace trimmed)]
                             [status (car parts)]
                             [path (trim (substring trimmed (string-length status) (string-length trimmed)))])
                        (hash 'type 'entry 'section 'unstaged 'status status 'path path))]
                     [(starts-with? prev-line "Staged (")
                      (let* ([trimmed (trim line)]
                             [parts (split-whitespace trimmed)]
                             [status (car parts)]
                             [raw-path (trim (substring trimmed (string-length status) (string-length trimmed)))]
                             [path (if (and (string=? status "R") (string-contains? raw-path " -> "))
                                       (list-ref (split-many raw-path " -> ") 1)
                                       raw-path)])
                        (hash 'type 'entry 'section 'staged 'status status 'path path 'raw-path raw-path))]
                     [(starts-with? prev-line "Untracked (")
                      (let* ([trimmed (trim line)]
                             [parts (split-whitespace trimmed)]
                             [status (car parts)]
                             [path (trim (substring trimmed (string-length status) (string-length trimmed)))])
                        (hash 'type 'entry 'section 'untracked 'status "?" 'path path))]
                     [(starts-with? prev-line "Recent Commits (")
                      (let* ([trimmed (trim line)]
                             [parts (split-whitespace trimmed)]
                             [c-hash (car parts)]
                             [subj (trim (substring trimmed (string-length c-hash) (string-length trimmed)))])
                        (hash 'type 'commit 'hash c-hash 'subject subj))]
                     [(and (> (string-length prev-line) 0)
                           (not (starts-with? prev-line "  "))
                           (not (string-contains? prev-line "(")))
                      (hash 'type 'none)]
                     [else (loop (- idx 1))]))))]
          [else (hash 'type 'none)]))))

;; Stage the target at cursor
(define (git-stage-target! dir target)
  (let ([t (hash-ref target 'type)])
    (cond
      [(eq? t 'entry)
       (let ([sec (hash-ref target 'section)]
             [path (hash-ref target 'path)])
         (cond
           [(or (eq? sec 'unstaged) (eq? sec 'untracked) (eq? sec 'unmerged))
            (let ([res (git-exec dir (list "add" "--" path))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Staged: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'staged)
            (hash 'success #true 'message (string-append "Already staged: " path))]
           [else (hash 'success #false 'message "Unknown section")]))]
      [(eq? t 'section-header)
       (let ([sec (hash-ref target 'section)])
         (cond
           [(eq? sec 'unstaged)
            (let ([res (git-exec dir '("add" "-u"))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message "Staged all unstaged changes")
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'untracked)
            (let ([res (git-exec dir '("add" "."))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message "Staged all untracked files")
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'unmerged)
            (let ([res (git-exec dir '("add" "-u"))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message "Marked conflicts as resolved")
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [else (hash 'success #false 'message "Cannot stage this section")]))]
      [else (hash 'success #false 'message "Nothing to stage under cursor")])))

;; Unstage the target at cursor
(define (git-unstage-target! dir target)
  (let ([t (hash-ref target 'type)])
    (cond
      [(eq? t 'entry)
       (let ([sec (hash-ref target 'section)]
             [path (hash-ref target 'path)])
         (if (eq? sec 'staged)
             (let ([res (if (git-has-commits? dir)
                            (git-exec dir (list "restore" "--staged" "--" path))
                            (git-exec dir (list "rm" "--cached" "-q" "--" path)))])
               (if (hash-ref res 'ok)
                   (hash 'success #true 'message (string-append "Unstaged: " path))
                   (hash 'success #false 'message (hash-ref res 'stderr))))
             (hash 'success #false 'message (string-append "File is not staged: " path))))]
      [(eq? t 'section-header)
       (let ([sec (hash-ref target 'section)])
         (if (eq? sec 'staged)
             (let ([res (if (git-has-commits? dir)
                            (git-exec dir '("restore" "--staged" "."))
                            (git-exec dir '("rm" "--cached" "-r" "-q" ".")))])
               (if (hash-ref res 'ok)
                   (hash 'success #true 'message "Unstaged all staged changes")
                   (hash 'success #false 'message (hash-ref res 'stderr))))
             (hash 'success #false 'message "Cannot unstage this section")))]
      [else (hash 'success #false 'message "Nothing to unstage under cursor")])))

;; Stage every eligible entry in a list of targets (selection support).
;; Section headers are ignored here: selecting a header with s/u still uses
;; the single-target path, but a multi-line selection should never implicitly
;; stage or unstage a whole section.
(define (git-stage-targets! dir targets)
  (let ([staged '()]
        [errors '()]
        [skipped 0])
    (for-each
      (lambda (target)
        (when (eq? (hash-ref target 'type) 'entry)
          (let ([section (hash-ref target 'section)]
                [path (hash-ref target 'path)])
            (cond
              [(not (or (eq? section 'unstaged)
                        (eq? section 'untracked)
                        (eq? section 'unmerged)))
               (set! skipped (+ skipped 1))]
              [(member path staged) (set! skipped (+ skipped 1))]
              [else
               (let ([res (git-exec dir (list "add" "--" path))])
                 (if (hash-ref res 'ok)
                     (set! staged (cons path staged))
                     (set! errors
                           (cons (string-append path ": " (trim (hash-ref res 'stderr)))
                                 errors))))]))))
      targets)
    (let ([count (length staged)])
      (hash 'success (> count 0)
            'count count
            'message
            (string-append
              (if (> count 0)
                  (string-append "Staged " (number->string count)
                                 " file(s): " (string-join (reverse staged) ", "))
                  "Nothing to stage in selection")
              (if (null? errors)
                  ""
                  (string-append "; failed: " (string-join (reverse errors) "; ")))
              (if (> skipped 0)
                  (string-append " (skipped " (number->string skipped) ")")
                  ""))))))

;; Unstage every eligible entry in a list of targets (selection support).
(define (git-unstage-targets! dir targets)
  (let ([unstaged '()]
        [errors '()]
        [skipped 0])
    (for-each
      (lambda (target)
        (when (eq? (hash-ref target 'type) 'entry)
          (let ([section (hash-ref target 'section)]
                [path (hash-ref target 'path)])
            (cond
              [(not (eq? section 'staged))
               (set! skipped (+ skipped 1))]
              [(member path unstaged) (set! skipped (+ skipped 1))]
              [else
               (let ([res (if (git-has-commits? dir)
                              (git-exec dir (list "restore" "--staged" "--" path))
                              (git-exec dir (list "rm" "--cached" "-q" "--" path)))])
                 (if (hash-ref res 'ok)
                     (set! unstaged (cons path unstaged))
                     (set! errors
                           (cons (string-append path ": " (trim (hash-ref res 'stderr)))
                                 errors))))]))))
      targets)
    (let ([count (length unstaged)])
      (hash 'success (> count 0)
            'count count
            'message
            (string-append
              (if (> count 0)
                  (string-append "Unstaged " (number->string count)
                                 " file(s): " (string-join (reverse unstaged) ", "))
                  "Nothing to unstage in selection")
              (if (null? errors)
                  ""
                  (string-append "; failed: " (string-join (reverse errors) "; ")))
              (if (> skipped 0)
                  (string-append " (skipped " (number->string skipped) ")")
                  ""))))))

;; Toggle stage/unstage for target at cursor
(define (git-toggle-stage-target! dir target)
  (let ([t (hash-ref target 'type)])
    (cond
      [(eq? t 'entry)
       (let ([sec (hash-ref target 'section)])
         (if (eq? sec 'staged)
             (git-unstage-target! dir target)
             (git-stage-target! dir target)))]
      [(eq? t 'section-header)
       (let ([sec (hash-ref target 'section)])
         (if (eq? sec 'staged)
             (git-unstage-target! dir target)
             (git-stage-target! dir target)))]
      [else (hash 'success #false 'message "Nothing to toggle under cursor")])))

;; Discard changes for target at cursor
(define (git-discard-target! dir target)
  (let ([t (hash-ref target 'type)])
    (cond
      [(eq? t 'entry)
       (let ([sec (hash-ref target 'section)]
             [path (hash-ref target 'path)])
         (cond
           [(eq? sec 'unstaged)
            (let ([res (git-exec dir (list "restore" "--" path))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Discarded changes in: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'untracked)
            (let ([res (git-exec dir (list "clean" "-f" "-d" "--" path))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Deleted untracked file: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'staged)
            (let* ([_ (if (git-has-commits? dir)
                          (git-exec dir (list "restore" "--staged" "--" path))
                          (git-exec dir (list "rm" "--cached" "-q" "--" path)))]
                   [res (git-exec dir (list "restore" "--" path))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Discarded staged changes in: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [else (hash 'success #false 'message "Cannot discard entry in this section")]))]
      [(eq? t 'section-header)
       (let ([sec (hash-ref target 'section)])
         (cond
           [(eq? sec 'unstaged)
            (let ([res (git-exec dir '("restore" "."))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message "Discarded all unstaged changes")
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [(eq? sec 'untracked)
            (let ([res (git-exec dir '("clean" "-f" "-d" "."))])
              (if (hash-ref res 'ok)
                  (hash 'success #true 'message "Deleted all untracked files")
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
           [else (hash 'success #false 'message "Cannot discard this section")]))]
      [else (hash 'success #false 'message "Nothing to discard under cursor")])))

;; Stage all changes (tracked and untracked)
(define (git-stage-all! dir)
  (let ([res (git-exec dir '("add" "-A"))])
    (if (hash-ref res 'ok)
        (hash 'success #true 'message "Staged all changes")
        (hash 'success #false 'message (hash-ref res 'stderr)))))

;; Unstage all changes
(define (git-unstage-all! dir)
  (let ([res (if (git-has-commits? dir)
                 (git-exec dir '("restore" "--staged" "."))
                 (git-exec dir '("rm" "--cached" "-r" "-q" ".")))])
    (if (hash-ref res 'ok)
        (hash 'success #true 'message "Unstaged all changes")
        (hash 'success #false 'message (hash-ref res 'stderr)))))

;; Commit with message
(define (git-commit! dir message [amend? #false])
  (let* ([args (if amend?
                   (list "commit" "--amend" "-m" message)
                   (list "commit" "-m" message))]
         [res (git-exec dir args)])
    (if (hash-ref res 'ok)
        (hash 'success #true 'message "Commit successful" 'output (hash-ref res 'stdout))
        (hash 'success #false 'message (hash-ref res 'stderr) 'output (hash-ref res 'stderr)))))

;; Get diff text for target or whole repo
(define (git-diff-target dir target)
  (let ([t (hash-ref target 'type)])
    (cond
      [(eq? t 'entry)
       (let ([sec (hash-ref target 'section)]
             [path (hash-ref target 'path)])
         (cond
           [(eq? sec 'staged)
            (let ([res (git-exec dir (list "diff" "--staged" "--" path))])
              (hash-ref res 'stdout))]
           [(eq? sec 'unstaged)
            (let ([res (git-exec dir (list "diff" "--" path))])
              (hash-ref res 'stdout))]
           [(eq? sec 'unmerged)
            (let ([res (git-exec dir (list "diff" "--" path))])
              (hash-ref res 'stdout))]
           [(eq? sec 'untracked)
            (let ([res (git-exec dir (list "diff" "--no-index" "/dev/null" path))])
              (hash-ref res 'stdout))]
           [else ""]))]
      [(eq? t 'commit)
       (let ([res (git-exec dir (list "show" (hash-ref target 'hash)))])
         (hash-ref res 'stdout))]
      [else
       (let ([res (if (git-has-commits? dir)
                      (git-exec dir '("diff" "HEAD"))
                      (git-exec dir '("diff")))])
         (hash-ref res 'stdout))])))

;; Push current branch
(define (git-push! dir)
  (let ([res (git-exec dir '("push"))])
    (if (hash-ref res 'ok)
        (hash 'success #true 'message "Push successful" 'output (hash-ref res 'stdout))
        (hash 'success #false 'message (if (string=? (trim (hash-ref res 'stderr)) "")
                                           (hash-ref res 'stdout)
                                           (hash-ref res 'stderr))))))

;; Pull current branch
(define (git-pull! dir)
  (let ([res (git-exec dir '("pull"))])
    (if (hash-ref res 'ok)
        (hash 'success #true 'message "Pull successful" 'output (hash-ref res 'stdout))
        (hash 'success #false 'message (if (string=? (trim (hash-ref res 'stderr)) "")
                                           (hash-ref res 'stdout)
                                           (hash-ref res 'stderr))))))

;; Resolve conflict using OURS version and stage
(define (git-resolve-ours! dir path)
  (let ([res1 (git-exec dir (list "checkout" "--ours" "--" path))])
    (if (hash-ref res1 'ok)
        (let ([res2 (git-exec dir (list "add" "--" path))])
          (if (hash-ref res2 'ok)
              (hash 'success #true 'message (string-append "Resolved (OURS): " path))
              (hash 'success #false 'message (hash-ref res2 'stderr))))
        (hash 'success #false 'message (hash-ref res1 'stderr)))))

;; Resolve conflict using THEIRS version and stage
(define (git-resolve-theirs! dir path)
  (let ([res1 (git-exec dir (list "checkout" "--theirs" "--" path))])
    (if (hash-ref res1 'ok)
        (let ([res2 (git-exec dir (list "add" "--" path))])
          (if (hash-ref res2 'ok)
              (hash 'success #true 'message (string-append "Resolved (THEIRS): " path))
              (hash 'success #false 'message (hash-ref res2 'stderr))))
        (hash 'success #false 'message (hash-ref res1 'stderr)))))

;; Extract entry path from a line
(define (extract-entry-path line)
  (let* ([trimmed (trim line)]
         [parts (split-whitespace trimmed)])
    (if (null? parts)
        #false
        (let* ([status (car parts)]
               [raw (trim (substring trimmed (string-length status) (string-length trimmed)))])
          (if (and (string=? status "R") (string-contains? raw " -> "))
              (list-ref (split-many raw " -> ") 1)
              raw)))))

;; Parse buffer lines into section buckets: staged, unstaged, untracked, unmerged
(define (parse-buffer-sections lines)
  (let ([cur-sec 'none]
        [staged '()]
        [unstaged '()]
        [untracked '()]
        [unmerged '()])
    (for-each
      (lambda (line)
        (cond
          [(starts-with? line "Staged (") (set! cur-sec 'staged)]
          [(starts-with? line "Unstaged (") (set! cur-sec 'unstaged)]
          [(starts-with? line "Untracked (") (set! cur-sec 'untracked)]
          [(starts-with? line "Unmerged (") (set! cur-sec 'unmerged)]
          [(starts-with? line "Recent Commits (") (set! cur-sec 'recent-commits)]
          [(and (> (string-length line) 0)
                (not (starts-with? line "  "))
                (not (starts-with? line "Keys:"))
                (not (starts-with? line "Head:"))
                (not (starts-with? line "Repo:"))
                (not (starts-with? line "Help:")))
           (set! cur-sec 'none)]
          [(starts-with? line "  ")
           (let ([path (extract-entry-path line)])
             (when (and path (> (string-length path) 0))
               (cond
                 [(eq? cur-sec 'staged) (set! staged (cons path staged))]
                 [(eq? cur-sec 'unstaged) (set! unstaged (cons path unstaged))]
                 [(eq? cur-sec 'untracked) (set! untracked (cons path untracked))]
                 [(eq? cur-sec 'unmerged) (set! unmerged (cons path unmerged))]
                 [else #f])))]
          [else #f]))
      lines)
    (hash 'staged (reverse staged)
          'unstaged (reverse unstaged)
          'untracked (reverse untracked)
          'unmerged (reverse unmerged))))

;; Compute save actions when user edits the buffer directly like oil
(define (calculate-save-actions orig curr)
  (let* ([orig-staged (hash-ref orig 'staged)]
         [orig-unstaged (hash-ref orig 'unstaged)]
         [orig-untracked (hash-ref orig 'untracked)]
         [curr-staged (hash-ref curr 'staged)]
         [curr-unstaged (hash-ref curr 'unstaged)]
         [curr-untracked (hash-ref curr 'untracked)]
         [curr-all (append curr-staged (append curr-unstaged curr-untracked))]
         [to-stage (filter (lambda (f)
                             (and (member f curr-staged)
                                  (or (member f orig-unstaged)
                                      (member f orig-untracked))))
                           curr-staged)]
         [to-unstage (filter (lambda (f)
                               (and (member f curr-unstaged)
                                    (member f orig-staged)))
                             curr-unstaged)]
         [staged-deleted (filter (lambda (f)
                                   (and (member f orig-staged)
                                        (not (member f curr-all))))
                                 orig-staged)]
         [unstaged-deleted (filter (lambda (f)
                                     (and (member f orig-unstaged)
                                          (not (member f curr-all))))
                                   orig-unstaged)]
         [untracked-deleted (filter (lambda (f)
                                      (and (member f orig-untracked)
                                           (not (member f curr-all))))
                                    orig-untracked)])
    (hash 'stage to-stage
          'unstage (append to-unstage staged-deleted)
          'discard unstaged-deleted
          'clean untracked-deleted)))

;; =============================================================================
;; Helix Editor Buffer Lifecycle
;; =============================================================================

(define (git-buffer-alive?)
  (and *xit-doc-id* (editor-doc-exists? *xit-doc-id*)))

(define (commit-buffer-alive?)
  (and *xit-commit-doc-id* (editor-doc-exists? *xit-commit-doc-id*)))

(define (diff-buffer-alive?)
  (and *xit-diff-doc-id* (editor-doc-exists? *xit-diff-doc-id*)))

;; Refresh the status buffer content
(define (refresh-git-buffer! [target-line #false])
  (when (and *xit-dir* (git-buffer-alive?))
    (let* ([head-info (git-head-info *xit-dir*)]
           [entries   (git-status-entries *xit-dir*)]
           [commits   (git-recent-commits *xit-dir* 5)]
           [text-buf  (format-status-buffer *xit-dir* head-info entries commits *xit-show-help*)]
           [lines     (split-many text-buf "\n")]
           [cur-line  (or target-line (get-current-line-number))]
           [safe-line (max 0 (min cur-line (- (length lines) 1)))])
      ;; Store original state for buffer-editing diffing
      (set! *xit-original-sections*
            (hash 'staged (map cdr (hash-ref entries 'staged))
                  'unstaged (map cdr (hash-ref entries 'unstaged))
                  'untracked (hash-ref entries 'untracked)
                  'unmerged (map cdr (hash-ref entries 'unmerged))))
      (select_all)
      (replace-selection-with text-buf)
      (collapse_selection)
      (helix.goto-line (+ safe-line 1)))))

;; Open or focus the git status buffer
(define (open-git-for-dir dir)
  (let* ([canonical (with-handler (lambda (_) dir) (canonicalize-path dir))]
         [repo-root (git-repo-root canonical)])
    (if (not repo-root)
        (xit-error (string-append "Not a git repository: " canonical))
        (begin
          (set! *xit-dir* repo-root)
          (if (git-buffer-alive?)
              (begin
                (editor-switch-action! *xit-doc-id* (Action/Replace))
                (refresh-git-buffer!)
                (xit-set-buffer-language! "git-commit"))
              (begin
                (helix.new)
                (enqueue-thread-local-callback
                  (lambda ()
                    (let* ([view-id (editor-focus)]
                           [doc-id  (editor->doc-id view-id)])
                      (set! *xit-doc-id* doc-id)
                      (set-scratch-buffer-name! XIT-BUFFER-NAME)
                      (xit-install-buffer-keymap! XIT-BUFFER-NAME XIT-KEYMAPS)
                      (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-BUFFER-NAME)
                      (refresh-git-buffer! 4)
                      (xit-set-buffer-language! "git-commit"))))))))))

;; Get the target under the current cursor in *git* buffer
(define (current-buffer-target)
  (if (git-buffer-alive?)
      (let* ([rope (editor->text *xit-doc-id*)]
             [text (text.rope->string rope)]
             [lines (split-many text "\n")]
             [line-n (get-current-line-number)])
        (parse-line-target lines line-n))
      (hash 'type 'none)))

;; Remove duplicate line numbers, keeping their original order.
(define (xit-unique-lines lines)
  (let loop ([remaining lines] [seen '()] [result '()])
    (cond
      [(null? remaining) (reverse result)]
      [(member (car remaining) seen) (loop (cdr remaining) seen result)]
      [else (loop (cdr remaining)
                  (cons (car remaining) seen)
                  (cons (car remaining) result))])))

;; All 0-indexed lines covered by the current Helix selection in *git*.
;; A single cursor yields one line; a vertical selection or multiple cursors
;; yield every line they touch.
(define (current-selection-line-numbers)
  (if (git-buffer-alive?)
      (let* ([rope (editor->text *xit-doc-id*)]
             [len (text.rope-len-chars rope)]
             [line-count (text.rope-len-lines rope)]
             [ranges (selection->ranges (current-selection-object))]
             [lines '()])
        (for-each
          (lambda (range)
            (let* ([span (range->span range)]
                   [from (min (car span) len)]
                   [to (min (cadr span) len)]
                   [start (text.rope-char->line rope from)]
                   [end (text.rope-char->line rope to)])
              (let loop ([ln start])
                (when (<= ln end)
                  (set! lines (cons ln lines))
                  (loop (+ ln 1))))))
          ranges)
        (filter (lambda (ln) (and (>= ln 0) (< ln line-count)))
                (xit-unique-lines (reverse lines))))
      '()))

;; Resolve the targets for an explicit list of 0-indexed lines.
(define (targets-for-lines line-numbers)
  (if (git-buffer-alive?)
      (let* ([rope (editor->text *xit-doc-id*)]
             [lines (split-many (text.rope->string rope) "\n")])
        (map (lambda (ln) (parse-line-target lines ln)) line-numbers))
      '()))

(define (current-selection-targets)
  (targets-for-lines (current-selection-line-numbers)))

;; =============================================================================
;; Commands
;; =============================================================================

;;@doc
;; Open interactive Git status buffer (like vim-fugitive :Git)
;; Can also be called with subcommands: :Git commit, :Git diff, :Git push, etc.
(define (Git . args)
  (if (null? args)
      (let* ([doc-id (editor->doc-id (editor-focus))]
             [path   (editor-document->path doc-id)]
             [dir    (if path (parent-name path) (get-helix-cwd))])
        (open-git-for-dir dir))
      (let ([subcmd (car args)])
        (cond
          [(string=? subcmd "commit") (git-commit)]
          [(string=? subcmd "diff")   (git-diff)]
          [(string=? subcmd "push")   (git-push)]
          [(string=? subcmd "pull")   (git-pull)]
          [(string=? subcmd "status") (Git)]
          [(string=? subcmd "help")   (git-help)]
          [(string=? subcmd "stage")  (git-stage)]
          [(string=? subcmd "unstage")(git-unstage)]
          [(string=? subcmd "stage-selection")   (git-stage-selection)]
          [(string=? subcmd "unstage-selection") (git-unstage-selection)]
          [else
           (unless *xit-dir*
             (set! *xit-dir* (git-repo-root (get-helix-cwd))))
           (if *xit-dir*
               (let ([res (git-exec *xit-dir* args)])
                 (if (hash-ref res 'ok)
                     (begin
                       (let ([out (trim (hash-ref res 'stdout))])
                         (if (string=? out "")
                             (xit-info (string-append "git " (string-join args " ") " succeeded"))
                             (xit-info out)))
                       (when (git-buffer-alive?) (refresh-git-buffer!)))
                     (xit-error (hash-ref res 'stderr))))
               (xit-error "Not in a git repository"))]))))

(define (git . args) (apply Git args))
(define (xit . args) (apply Git args))

;;@doc
;; Stage every selected file in the git buffer (Helix multi-cursor / line selection)
(define (git-stage-selection)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let ([res (git-stage-targets! *xit-dir* (current-selection-targets))])
      (if (hash-ref res 'success)
          (begin
            (xit-info (hash-ref res 'message))
            (refresh-git-buffer!))
          (xit-error (hash-ref res 'message))))))

(define (xit-stage-selection) (git-stage-selection))

;;@doc
;; Unstage every selected file in the git buffer (undo staging for a selection)
(define (git-unstage-selection)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let ([res (git-unstage-targets! *xit-dir* (current-selection-targets))])
      (if (hash-ref res 'success)
          (begin
            (xit-info (hash-ref res 'message))
            (refresh-git-buffer!))
          (xit-error (hash-ref res 'message))))))

(define (xit-unstage-selection) (git-unstage-selection))

;;@doc
;; Stage file or section under cursor, or all selected files when a selection
;; spans more than one line (or mark conflict as resolved)
(define (git-stage)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (if (> (length (current-selection-line-numbers)) 1)
        (git-stage-selection)
        (let ([res (git-stage-target! *xit-dir* (current-buffer-target))])
          (if (hash-ref res 'success)
              (begin
                (xit-info (hash-ref res 'message))
                (refresh-git-buffer!))
              (xit-error (hash-ref res 'message)))))))

(define (xit-stage) (git-stage))

;;@doc
;; Unstage file or section under cursor, or all selected files when a selection
;; spans more than one line
(define (git-unstage)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (if (> (length (current-selection-line-numbers)) 1)
        (git-unstage-selection)
        (let ([res (git-unstage-target! *xit-dir* (current-buffer-target))])
          (if (hash-ref res 'success)
              (begin
                (xit-info (hash-ref res 'message))
                (refresh-git-buffer!))
              (xit-error (hash-ref res 'message)))))))

(define (xit-unstage) (git-unstage))

;;@doc
;; Toggle staging for file or section under cursor
(define (git-toggle-stage)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let* ([target (current-buffer-target)]
           [res (git-toggle-stage-target! *xit-dir* target)])
      (if (hash-ref res 'success)
          (begin
            (xit-info (hash-ref res 'message))
            (refresh-git-buffer!))
          (xit-error (hash-ref res 'message))))))

(define (xit-toggle-stage) (git-toggle-stage))

;;@doc
;; Stage all changes in repository
(define (git-stage-all)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
      (let ([res (git-stage-all! *xit-dir*)])
        (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (when (git-buffer-alive?) (refresh-git-buffer!)))
            (xit-error (hash-ref res 'message))))
      (xit-error "Not in a git repository")))

(define (xit-stage-all) (git-stage-all))

;;@doc
;; Unstage all changes in repository
(define (git-unstage-all)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
      (let ([res (git-unstage-all! *xit-dir*)])
        (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (when (git-buffer-alive?) (refresh-git-buffer!)))
            (xit-error (hash-ref res 'message))))
      (xit-error "Not in a git repository")))

(define (xit-unstage-all) (git-unstage-all))

;;@doc
;; Ask for confirmation before discarding changes under cursor
(define (git-discard)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let* ([target (current-buffer-target)]
           [label (if (eq? (hash-ref target 'type) 'entry)
                      (string-append "Discard " (hash-ref target 'path) "? type y to confirm: ")
                      "Discard this section? type y to confirm: ")])
      (push-component!
        (prompt label
          (lambda (answer)
            (when (or (string=? answer "y") (string=? answer "Y")
                      (string=? answer "yes") (string=? answer "YES"))
              (let ([res (git-discard-target! *xit-dir* target)])
                (if (hash-ref res 'success)
                    (begin
                      (xit-info (hash-ref res 'message))
                      (refresh-git-buffer!))
                    (xit-error (hash-ref res 'message))))))))))
  void)

(define (xit-discard) (git-discard))

;;@doc
;; Resolve conflicted file under cursor using OURS version (current branch)
(define (git-resolve-ours)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let ([target (current-buffer-target)])
      (if (and (eq? (hash-ref target 'type) 'entry)
               (eq? (hash-ref target 'section) 'unmerged))
          (let* ([path (hash-ref target 'path)]
                 [res  (git-resolve-ours! *xit-dir* path)])
            (if (hash-ref res 'success)
                (begin
                  (xit-info (hash-ref res 'message))
                  (refresh-git-buffer!))
                (xit-error (hash-ref res 'message))))
          (xit-error "Cursor is not on an unmerged conflicted file")))))

(define (xit-resolve-ours) (git-resolve-ours))

;;@doc
;; Resolve conflicted file under cursor using THEIRS version (incoming branch)
(define (git-resolve-theirs)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let ([target (current-buffer-target)])
      (if (and (eq? (hash-ref target 'type) 'entry)
               (eq? (hash-ref target 'section) 'unmerged))
          (let* ([path (hash-ref target 'path)]
                 [res  (git-resolve-theirs! *xit-dir* path)])
            (if (hash-ref res 'success)
                (begin
                  (xit-info (hash-ref res 'message))
                  (refresh-git-buffer!))
                (xit-error (hash-ref res 'message))))
          (xit-error "Cursor is not on an unmerged conflicted file")))))

(define (xit-resolve-theirs) (git-resolve-theirs))

;;@doc
;; Open file under cursor in Helix (or resolve conflict markers manually)
(define (git-open)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let ([target (current-buffer-target)])
      (cond
        [(eq? (hash-ref target 'type) 'entry)
         (helix.open (path-join *xit-dir* (hash-ref target 'path)))]
        [(eq? (hash-ref target 'type) 'commit)
         (git-diff)]
        [else
         (xit-info "No file under cursor to open")]))))

(define (xit-open) (git-open))

;;@doc
;; Show git diff for file under cursor or entire repository
(define (git-diff)
  (unless (git-buffer-alive?)
    (let ([cwd (get-helix-cwd)])
      (when (git-repo? cwd)
        (set! *xit-dir* (git-repo-root cwd)))))
  (unless *xit-dir*
    (xit-error "Not in a git repository"))
  (when *xit-dir*
    (let* ([target (if (git-buffer-alive?)
                       (current-buffer-target)
                       (hash 'type 'none))]
           [diff-text (git-diff-target *xit-dir* target)])
      (if (string=? (trim diff-text) "")
          (xit-info "No diff to display")
          (if (diff-buffer-alive?)
              (begin
                (editor-switch-action! *xit-diff-doc-id* (Action/Replace))
                (select_all)
                (replace-selection-with diff-text)
                (collapse_selection)
                (helix.goto-line 1)
                (xit-set-buffer-language! "git-diff" "diff"))
              (begin
                (helix.new)
                (enqueue-thread-local-callback
                  (lambda ()
                    (let* ([view-id (editor-focus)]
                           [doc-id  (editor->doc-id view-id)])
                      (set! *xit-diff-doc-id* doc-id)
                      (set-scratch-buffer-name! XIT-DIFF-BUFFER-NAME)
                      (xit-install-buffer-keymap! XIT-DIFF-BUFFER-NAME XIT-DIFF-KEYMAPS)
                      (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-DIFF-BUFFER-NAME)
                      (insert_string diff-text)
                      (helix.goto-line 1)
                      (xit-set-buffer-language! "git-diff" "diff"))))))))))

(define (xit-diff) (git-diff))


;; Path used for the Git-like commit editor. --path-format keeps this absolute
;; and works for worktrees too.
(define (xit-commit-message-path)
  (let* ([res (git-exec *xit-dir*
                        '("rev-parse" "--path-format=absolute" "--git-path"
                          "XIT_COMMIT_EDITMSG"))]
         [out (trim (hash-ref res 'stdout))])
    (if (and (hash-ref res 'ok) (> (string-length out) 0))
        out
        (path-join *xit-dir* (path-join ".git" "XIT_COMMIT_EDITMSG")))))

(define (xit-write-commit-file! path content)
  (when (path-exists? path)
    (delete-file! path))
  (call-with-output-file path
    (lambda (out) (display content out)))
  void)

(define (xit-reset-commit-state!)
  (set! *xit-commit-doc-id* #false)
  (set! *xit-commit-amend?* #false)
  (set! *xit-commit-path* #false)
  void)

;; Open the commit buffer as a real file so Helix :w works like git commit.
(define (open-commit-buffer! amend?)
  (set! *xit-commit-amend?* amend?)
  (let* ([path (xit-commit-message-path)]
         [prev-msg (if (and amend? (git-has-commits? *xit-dir*))
                       (let ([res (git-exec *xit-dir* '("log" "-1" "--pretty=%B"))])
                         (if (hash-ref res 'ok) (trim (hash-ref res 'stdout)) ""))
                       "")]
         [st (git-status-entries *xit-dir*)]
         [staged (hash-ref st 'staged)]
         [template
          (string-append
            (if (string=? prev-msg "") "" (string-append prev-msg "\n\n"))
            "\n"
            "# Please enter the commit message for your changes. Lines starting\n"
            "# with '#' will be ignored, and an empty message aborts the commit.\n"
            "# [:w] finishes the commit   [q] aborts\n"
            "#\n"
            "# Changes to be committed:\n"
            (if (null? staged)
                "#   (none)\n"
                (string-join (map (lambda (p) (string-append "#   " (car p) "  " (cdr p))) staged) "\n"))
            "\n")])
    (set! *xit-commit-path* path)
    (xit-write-commit-file! path template)
    (if (commit-buffer-alive?)
        (begin
          (editor-switch-action! *xit-commit-doc-id* (Action/Replace))
          (editor-document-reload *xit-commit-doc-id*)
          (helix.goto-line 1)
          (xit-set-buffer-language! "git-commit"))
        (begin
          (helix.open path)
          (enqueue-thread-local-callback
            (lambda ()
              (let* ([view-id (editor-focus)]
                     [doc-id  (editor->doc-id view-id)])
                (set! *xit-commit-doc-id* doc-id)
                (set-scratch-buffer-name! XIT-COMMIT-BUFFER-NAME)
                (xit-install-buffer-keymap! XIT-COMMIT-BUFFER-NAME XIT-COMMIT-KEYMAPS)
                (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-COMMIT-BUFFER-NAME)
                (editor-document-reload doc-id)
                (helix.goto-line 1)
                (xit-set-buffer-language! "git-commit")))))))
  void)

;;@doc
;; Open commit buffer for staged changes
(define (git-commit)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (unless *xit-dir*
    (xit-error "Not in a git repository"))
  (when *xit-dir*
    (let* ([st (git-status-entries *xit-dir*)]
           [staged (hash-ref st 'staged)])
      (if (null? staged)
          (xit-error "No changes staged. Press 's' to stage files, or 'S' to stage all.")
          (open-commit-buffer! #false)))))

(define (xit-commit) (git-commit))

;;@doc
;; Amend the previous commit
(define (git-commit-amend)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (unless *xit-dir*
    (xit-error "Not in a git repository"))
  (when *xit-dir*
    (if (git-has-commits? *xit-dir*)
        (open-commit-buffer! #true)
        (xit-error "No existing commits to amend"))))

(define (xit-commit-amend) (git-commit-amend))

;;@doc
;; Finalize and create commit from commit buffer. Also used by the
;; document-saved hook when the user presses :w in the commit editor.
(define (git-commit-finish)
  (unless (commit-buffer-alive?)
    (xit-error "No active commit buffer"))
  (when (and (commit-buffer-alive?) (not *xit-commit-finishing?*))
    (set! *xit-commit-finishing?* #true)
    (with-handler
      (lambda (_)
        (set! *xit-commit-finishing?* #false)
        (xit-error "Commit failed unexpectedly")
        void)
      (let* ([rope (editor->text *xit-commit-doc-id*)]
             [text (text.rope->string rope)]
             [lines (split-many text "\n")]
             [content-lines (filter (lambda (l)
                                      (let ([t (trim l)])
                                        (not (or (starts-with? t "#") (string=? t "")))))
                                  lines)]
             [final-msg (trim (string-join content-lines "\n"))])
        (if (string=? final-msg "")
            (begin
              (helix.buffer-close!)
              (xit-info "Commit aborted: empty commit message")
              (xit-reset-commit-state!))
            (let ([res (git-commit! *xit-dir* final-msg *xit-commit-amend?*)])
              (if (hash-ref res 'success)
                  (begin
                    (helix.buffer-close!)
                    (let ([first-line (if (pair? content-lines) (car content-lines) "commit")])
                      (xit-info (string-append "Committed: " first-line)))
                    (when (git-buffer-alive?)
                      (editor-switch-action! *xit-doc-id* (Action/Replace))
                      (refresh-git-buffer!))
                    (xit-reset-commit-state!))
                  (xit-error (string-append "Commit failed: " (hash-ref res 'message))))))))
    (set! *xit-commit-finishing?* #false))
  void)

(define (xit-commit-finish) (git-commit-finish))

;;@doc
;; Abort commit and close commit buffer
(define (git-commit-abort)
  (if (commit-buffer-alive?)
      (begin
        (helix.buffer-close!)
        (xit-reset-commit-state!)
        (xit-info "Commit cancelled"))
      (xit-error "No active commit buffer"))
  void)

(define (xit-commit-abort) (git-commit-abort))

;;@doc
;; Quick commit with message argument
(define (git-commit-msg msg)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
      (let ([res (git-commit! *xit-dir* msg #false)])
        (if (hash-ref res 'success)
            (begin
              (xit-info (string-append "Committed: " msg))
              (when (git-buffer-alive?) (refresh-git-buffer!)))
            (xit-error (hash-ref res 'message))))
      (xit-error "Not in a git repository")))

(define (xit-commit-msg msg) (git-commit-msg msg))

;;@doc
;; Push current branch to remote
(define (git-push)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
      (let ([res (git-push! *xit-dir*)])
        (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (when (git-buffer-alive?) (refresh-git-buffer!)))
            (xit-error (hash-ref res 'message))))
      (xit-error "Not in a git repository")))

(define (xit-push) (git-push))

;;@doc
;; Pull current branch from remote
(define (git-pull)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
      (let ([res (git-pull! *xit-dir*)])
        (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (when (git-buffer-alive?) (refresh-git-buffer!)))
            (xit-error (hash-ref res 'message))))
      (xit-error "Not in a git repository")))

(define (xit-pull) (git-pull))

;;@doc
;; Refresh the git status buffer
(define (git-refresh)
  (if (git-buffer-alive?)
      (begin
        (refresh-git-buffer!)
        (xit-info "Status refreshed"))
      (xit-error "No active git buffer")))

(define (xit-refresh) (git-refresh))

;;@doc
;; Toggle keybinding cheat sheet in git buffer
(define (git-help)
  (if (git-buffer-alive?)
      (begin
        (set! *xit-show-help* (not *xit-show-help*))
        (refresh-git-buffer!))
      (xit-error "No active git buffer")))

(define (xit-help) (git-help))

;;@doc
;; Close the active git buffer
(define (git-close)
  (helix.buffer-close!))

(define (xit-close) (git-close))

;;@doc
;; Save and apply buffer edits to git (oil-style buffer management)
(define (git-save)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (and (git-buffer-alive?) *xit-dir*)
    (let* ([rope (editor->text *xit-doc-id*)]
           [text (text.rope->string rope)]
           [lines (split-many text "\n")]
           [curr-secs (parse-buffer-sections lines)]
           [actions (calculate-save-actions (or *xit-original-sections*
                                                (hash 'staged '() 'unstaged '() 'untracked '()))
                                            curr-secs)]
           [to-stage (hash-ref actions 'stage)]
           [to-unstage (hash-ref actions 'unstage)]
           [to-discard (hash-ref actions 'discard)]
           [to-clean (hash-ref actions 'clean)])
      (define summaries '())
      ;; Staging
      (for-each
        (lambda (p)
          (let ([res (git-stage-target! *xit-dir* (hash 'type 'entry 'section 'unstaged 'path p))])
            (when (hash-ref res 'success)
              (set! summaries (cons (string-append "Staged " p) summaries)))))
        to-stage)
      ;; Unstaging
      (for-each
        (lambda (p)
          (let ([res (git-unstage-target! *xit-dir* (hash 'type 'entry 'section 'staged 'path p))])
            (when (hash-ref res 'success)
              (set! summaries (cons (string-append "Unstaged " p) summaries)))))
        to-unstage)
      ;; Discarding
      (for-each
        (lambda (p)
          (let ([res (git-discard-target! *xit-dir* (hash 'type 'entry 'section 'unstaged 'path p))])
            (when (hash-ref res 'success)
              (set! summaries (cons (string-append "Discarded " p) summaries)))))
        to-discard)
      ;; Cleaning untracked
      (for-each
        (lambda (p)
          (let ([res (git-discard-target! *xit-dir* (hash 'type 'entry 'section 'untracked 'path p))])
            (when (hash-ref res 'success)
              (set! summaries (cons (string-append "Deleted " p) summaries)))))
        to-clean)
      (if (null? summaries)
          (xit-info "No changes to apply")
          (xit-info (string-join (reverse summaries) ", ")))
      (refresh-git-buffer!))))

(define (xit-save) (git-save))

;; =============================================================================
;; Keymap Definition Hashes (Configurable)
;; =============================================================================

(define XIT-KEYMAPS
  (hash
    "normal"
    (hash
      "s"    ":git-stage"
      "u"    ":git-unstage"
      "d"    ":git-discard"
      "ret"  ":git-open"
      "D"    ":git-diff"
      "O"    ":git-resolve-ours"
      "T"    ":git-resolve-theirs"
      "c"    ":git-commit"
      "C"    ":git-commit-amend"
      "S"    ":git-stage-all"
      "U"    ":git-unstage-all"
      "P"    ":git-push"
      "p"    ":git-pull"
      "r"    ":git-refresh"
      "q"    ":git-close"
      "?"    ":git-help")))

(define XIT-COMMIT-KEYMAPS
  (hash
    "normal"
    (hash
      "q"    ":git-commit-abort"
      "esc"  ":git-commit-abort")))

(define XIT-DIFF-KEYMAPS
  (hash
    "normal"
    (hash
      "q"    ":git-close")))

;; Git-like commit: :w on the commit editor saves the message file and commits.
(define (xit-on-document-saved! doc-id)
  (when (and *xit-commit-doc-id* (equal? doc-id *xit-commit-doc-id*))
    (git-commit-finish))
  void)

(unless *xit-save-hook-registered?*
  (set! *xit-save-hook-registered?* #true)
  (register-hook 'document-saved xit-on-document-saved!))

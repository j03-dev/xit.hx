;; xit-core.scm -- Git layer for xit.hx.
;; SPDX-License-Identifier: MIT OR Apache-2.0
;;
;; Pure Git logic: no Helix buffers, commands, keymaps or notifications live
;; here. xit.scm requires this module and provides the editor-facing layer.

(require-builtin steel/process)

(provide path-join
  git-exec
  git-repo?
  git-repo-root
  git-has-commits?
  parse-branch-header
  parse-porcelain-status
  git-head-info
  git-status-entries
  git-recent-commits
  format-status-buffer
  parse-line-target
  git-stage-target!
  git-unstage-target!
  git-stage-targets!
  git-unstage-targets!
  git-toggle-stage-target!
  git-discard-target!
  git-stage-all!
  git-unstage-all!
  git-commit!
  git-diff-target
  git-push!
  git-pull!
  git-resolve-ours!
  git-resolve-theirs!
  extract-entry-path
  parse-buffer-sections
  calculate-save-actions
  git-remote-async!)

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
             [err (if err-p (read-port-to-string err-p) "")]
             ;; Git writes progress to stderr even on success, so use the
             ;; exit status when available and fall back to stderr.
             [code (with-handler
                    (lambda (_) #false)
                    (let ([status (wait child)])
                      (if (Ok? status) (Ok->value status) #false)))]
             [ok (cond
                  [(equal? code 0) #true]
                  [(equal? code #false) (string=? (trim err) "")]
                  [else #false])])
        (hash 'ok ok
          'stdout
          out
          'stderr
          err))
      (hash 'ok #false
        'stdout
        ""
        'stderr
        "Failed to spawn git process"))))

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
          'status
          "No commits yet"
          'upstream
          #false
          'ahead
          0
          'behind
          0)]
      [(starts-with? raw "Initial commit on ")
        (hash 'branch (substring raw 18 (string-length raw))
          'status
          "No commits yet"
          'upstream
          #false
          'ahead
          0
          'behind
          0)]
      [(starts-with? raw "HEAD (no branch)")
        (hash 'branch "HEAD (detached)"
          'status
          "detached"
          'upstream
          #false
          'ahead
          0
          'behind
          0)]
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
            'status
            status-desc
            'upstream
            upstream
            'ahead
            0
            'behind
            0))])))

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
      'staged
      (reverse staged)
      'unstaged
      (reverse unstaged)
      'untracked
      (reverse untracked)
      'unmerged
      (reverse unmerged))))

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
        'staged
        '()
        'unstaged
        '()
        'untracked
        '()
        'unmerged
        '()))))

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
(define (format-status-buffer repo-dir head-info entries recent-commits show-help? [expanded-paths '()])
  (let* ([branch-str (hash-ref head-info 'branch)]
         [status-str (hash-ref head-info 'status)]
         [unmerged (hash-ref entries 'unmerged)]
         [unstaged (hash-ref entries 'unstaged)]
         [staged (hash-ref entries 'staged)]
         [untracked (hash-ref entries 'untracked)]
         [out-lines '()])

    (define (emit! line)
      (set! out-lines (cons line out-lines)))

    ;; File entries are foldable: "> " is collapsed, "v " is expanded with the
    ;; file's diff printed underneath, indented so it is never mistaken for an
    ;; entry by the buffer parsers.
    (define (emit-entry! status path section)
      (let ([expanded? (member path expanded-paths)])
        (emit! (string-append (if expanded? "v " "> ") status "  " path))
        (when expanded?
          (let ([diff (git-diff-target repo-dir
                       (hash 'type 'entry 'section section 'path path))])
            (for-each
              (lambda (line)
                (when (not (string=? line ""))
                  (emit! (string-append "    " line))))
              (split-many diff "\n"))))))

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
        (emit! "Keys:    [s] stage  [u] unstage  [d] discard (confirm)  [ret] fold diff  [D] diff  [v] select  [?] help")
        (emit! "")))

    ;; Unmerged (Conflicts)
    (when (not (null? unmerged))
      (emit! (string-append "Unmerged (" (number->string (length unmerged)) ")"))
      (for-each
        (lambda (item) (emit-entry! (car item) (cdr item) 'unmerged))
        unmerged)
      (emit! ""))

    ;; Unstaged
    (when (not (null? unstaged))
      (emit! (string-append "Unstaged (" (number->string (length unstaged)) ")"))
      (for-each
        (lambda (item) (emit-entry! (car item) (cdr item) 'unstaged))
        unstaged)
      (emit! ""))

    ;; Staged
    (when (not (null? staged))
      (emit! (string-append "Staged (" (number->string (length staged)) ")"))
      (for-each
        (lambda (item) (emit-entry! (car item) (cdr item) 'staged))
        staged)
      (emit! ""))

    ;; Untracked
    (when (not (null? untracked))
      (emit! (string-append "Untracked (" (number->string (length untracked)) ")"))
      (for-each
        (lambda (item) (emit-entry! "?" item 'untracked))
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
      (define (entry-from section)
        (let* ([trimmed (trim (substring line 2 (string-length line)))]
               [parts (split-whitespace trimmed)]
               [status (car parts)]
               [raw-path (trim (substring trimmed
                                (string-length status)
                                (string-length trimmed)))])
          (hash 'type 'entry
            'section
            section
            'status
            status
            'path
            (if (and (eq? section 'staged) (string=? status "R")
                 (string-contains? raw-path " -> "))
              (list-ref (split-many raw-path " -> ") 1)
              raw-path)
            'raw-path
            raw-path)))
      (cond
        ;; Inline diff body lines are never stageable targets.
        [(starts-with? line "    ") (hash 'type 'diff-line)]
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
        [(or (starts-with? line "> ") (starts-with? line "v "))
          (let loop ([idx (- line-n 1)])
            (if (< idx 0)
              (hash 'type 'none)
              (let ([prev-line (list-ref lines idx)])
                (cond
                  [(starts-with? prev-line "Unmerged (") (entry-from 'unmerged)]
                  [(starts-with? prev-line "Unstaged (") (entry-from 'unstaged)]
                  [(starts-with? prev-line "Staged (") (entry-from 'staged)]
                  [(starts-with? prev-line "Untracked (") (entry-from 'untracked)]
                  [(or (starts-with? prev-line "> ")
                      (starts-with? prev-line "v ")
                      (starts-with? prev-line "    "))
                    (loop (- idx 1))]
                  [(and (> (string-length prev-line) 0)
                      (not (starts-with? prev-line "  "))
                      (not (string-contains? prev-line "(")))
                    (hash 'type 'none)]
                  [else (loop (- idx 1))]))))]
        [(starts-with? line "  ")
          (let* ([trimmed (trim line)]
                 [parts (split-whitespace trimmed)]
                 [c-hash (car parts)]
                 [subj (trim (substring trimmed
                              (string-length c-hash)
                              (string-length trimmed)))])
            (hash 'type 'commit 'hash c-hash 'subject subj))]
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
        'count
        count
        'message
        (string-append
          (if (> count 0)
            (string-append "Staged " (number->string count)
              " file(s): "
              (string-join (reverse staged) ", "))
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
        'count
        count
        'message
        (string-append
          (if (> count 0)
            (string-append "Unstaged " (number->string count)
              " file(s): "
              (string-join (reverse unstaged) ", "))
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

;; Extract entry path from a line (fold markers and diff bodies are ignored)
(define (extract-entry-path line)
  (cond
    [(or (starts-with? line "    ") (not (or (starts-with? line "> ")
                                          (starts-with? line "v ")
                                          (starts-with? line "  "))))
      #false]
    [else
      (let* ([raw-line (if (or (starts-with? line "> ") (starts-with? line "v "))
                        (substring line 2 (string-length line))
                        line)]
             [trimmed (trim raw-line)]
             [parts (split-whitespace trimmed)])
        (if (null? parts)
          #false
          (let* ([status (car parts)]
                 [raw (trim (substring trimmed (string-length status) (string-length trimmed)))])
            (if (and (string=? status "R") (string-contains? raw " -> "))
              (list-ref (split-many raw " -> ") 1)
              raw))))]))

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
              (not (starts-with? line "> "))
              (not (starts-with? line "v "))
              (not (starts-with? line "Keys:"))
              (not (starts-with? line "Head:"))
              (not (starts-with? line "Repo:"))
              (not (starts-with? line "Help:")))
            (set! cur-sec 'none)]
          [(starts-with? line "    ") #f]
          [(or (starts-with? line "> ") (starts-with? line "v "))
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
      'unstaged
      (reverse unstaged)
      'untracked
      (reverse untracked)
      'unmerged
      (reverse unmerged))))

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
      'unstage
      (append to-unstage staged-deleted)
      'discard
      unstaged-deleted
      'clean
      untracked-deleted)))

;; -----------------------------------------------------------------------------
;; Background remote operations
;; -----------------------------------------------------------------------------

;; Run a blocking git command on a native thread. `on-done` is called with the
;; same result hash as `git-exec`, from the worker thread. Callers that touch
;; Helix must hand the work back with `hx.with-context`.
(define (git-remote-async! dir args on-done)
  (spawn-native-thread
    (lambda ()
      (let ([res (with-handler
                  (lambda (err) (hash 'ok #false 'stdout "" 'stderr (to-string err)))
                  (git-exec dir args))])
        (on-done res))))
  void)

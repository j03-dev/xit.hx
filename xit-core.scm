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
  git-branch-list
  git-branch-create!
  git-branch-checkout!
  git-branch-delete!
  git-branch-merge!
  git-branch-diff
  commit-display-lines
  commits-display-lines
  format-branch-buffer
  format-graph-buffer
  parse-branch-line
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

;; Git pathspecs interpret glob and magic syntax. Mark every path argument as
;; literal so spaces, brackets, leading '!' and leading ':' are just characters.
(define (git-pathspec path)
  (string-append ":(literal)" path))

;; Small helpers shared by the graph and branch renderers.
(define (all-but-last items)
  (if (null? items)
    '()
    (reverse (cdr (reverse items)))))

(define (digit-value ch)
  (let ([n (- (char->integer ch) 48)])
    (if (and (>= n 0) (<= n 9)) n #false)))

(define (xit-string->number value)
  (let loop ([i 0] [acc 0])
    (if (>= i (string-length value))
      acc
      (let ([d (digit-value (string-ref value i))])
        (if d
          (loop (+ i 1) (+ (* acc 10) d))
          acc)))))

(define (number-after-token text token)
  (let loop ([parts (split-whitespace text)])
    (cond
      [(null? parts) 0]
      [(string=? (car parts) token)
        (if (pair? (cdr parts)) (xit-string->number (cadr parts)) 0)]
      [else (loop (cdr parts))])))

;; Fixed-width columns used by the branch and commit views.
(define (pad-right text width)
  (let ([n (string-length text)])
    (if (>= n width)
      text
      (string-append text (make-string (- width n) #\space)))))

(define (max-string-length values)
  (let loop ([remaining values] [best 0])
    (if (null? remaining)
      best
      (loop (cdr remaining)
        (max best (string-length (car remaining)))))))

(define (hex-char? ch)
  (or (digit-value ch)
    (let ([n (char->integer ch)])
      (or (and (>= n 97) (<= n 102))
        (and (>= n 65) (<= n 70))))))

;; Find the first hex hash in a rendered commit line. Graph glyphs and the
;; author/subject come after it, so the first 7-40 char hex run is the hash.
(define (commit-hash-from-line line)
  (let ([len (string-length line)])
    (let loop ([i 0])
      (cond
        [(>= i len) #false]
        [(hex-char? (string-ref line i))
          (let scan ([j i])
            (if (and (< j len) (hex-char? (string-ref line j)))
              (scan (+ j 1))
              (let ([candidate (substring line i j)])
                (if (and (>= (string-length candidate) 7)
                     (<= (string-length candidate) 40))
                  candidate
                  (loop j)))))]
        [else (loop (+ i 1))]))))

(define (commit-subject-from-line line)
  (let ([hash (commit-hash-from-line line)]
        [len (string-length line)]
        [nbsp (integer->char 160)])
    (if hash
      (let ([hash-len (string-length hash)])
        (let loop ([i 0])
          (cond
            [(> (+ i hash-len) len) ""]
            [(string=? (substring line i (+ i hash-len)) hash)
              (let* ([start (+ i hash-len 1)]
                     [rest (substring line start len)]
                     [rest-len (string-length rest)])
                (let find-marker ([j 0])
                  (cond
                    [(>= j rest-len) rest]
                    [(char=? (string-ref rest j) nbsp)
                      (let ([subject-start (+ j 1)])
                        (if (< subject-start rest-len)
                          (substring rest subject-start rest-len)
                          ""))]
                    [else (find-marker (+ j 1))])))]
            [else (loop (+ i 1))])))
      "")))

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
      [(or (starts-with? raw "No commits yet on ")
          (starts-with? raw "Initial commit on "))
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
               [ahead (if info-part (number-after-token info-part "ahead") 0)]
               [behind (if info-part (number-after-token info-part "behind") 0)]
               [status-desc
                 (cond
                   [(not upstream) "local"]
                   [(and (= ahead 0) (= behind 0)) "up to date"]
                   [(and (> ahead 0) (> behind 0)) "diverged"]
                   [(> behind 0) "need pull"]
                   [else "need push"])])
          (hash 'branch branch
            'status
            status-desc
            'upstream
            upstream
            'ahead
            ahead
            'behind
            behind))])))

;; Parse `git status --porcelain=v1 -b -uall -z` output. NUL delimiting avoids
;; Git's C-style quoting, so paths with spaces or Unicode stay byte-exact.
(define (parse-porcelain-status output)
  (let* ([records (filter (lambda (r) (> (string-length r) 0))
                   (split-many output (string (integer->char 0))))]
         [branch-info (hash 'branch "HEAD" 'status "unknown" 'upstream #false 'ahead 0 'behind 0)]
         [staged '()]
         [unstaged '()]
         [untracked '()]
         [unmerged '()])
    (let loop ([items records])
      (when (pair? items)
        (let ([record (car items)]
              [rest (cdr items)])
          (cond
            [(starts-with? record "## ")
              (set! branch-info (parse-branch-header record))
              (loop rest)]
            [(>= (string-length record) 4)
              (let* ([x (string-ref record 0)]
                     [y (string-ref record 1)]
                     ;; record = "XY PATH"; no trim, so spaces are preserved.
                     [path (substring record 3 (string-length record))]
                     ;; Renames/copies carry the original path in the next field.
                     [next (if (or (char=? x #\R) (char=? y #\R)
                                (char=? x #\C)
                                (char=? y #\C))
                            (if (pair? rest) (cdr rest) rest)
                            rest)]
                     [status (string x y)])
                (cond
                  [(or (char=? x #\U) (char=? y #\U)
                      (and (char=? x #\A) (char=? y #\A))
                      (and (char=? x #\D) (char=? y #\D)))
                    (set! unmerged (cons (cons status path) unmerged))]
                  [(and (char=? x #\?) (char=? y #\?))
                    (set! untracked (cons path untracked))]
                  [else
                    (when (member x '(#\M #\A #\D #\R #\C))
                      (set! staged (cons (cons (string x) path) staged)))
                    (when (member y '(#\M #\D))
                      (set! unstaged (cons (cons (string y) path) unstaged)))])
                (loop next))]
            [else (loop rest)]))))
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
  (let ([res (git-exec dir '("status" "--porcelain=v1" "-b" "-uall" "-z"))])
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

;; Get all commits with Git's own graph prefix, author and decorations.
;; Record/unit separators keep graph glyphs out of the commit fields.
(define (parse-log-graph output sep fs)
  (let ([chunks (split-many output sep)])
    (if (null? chunks)
      '()
      (let loop ([remaining (cdr chunks)] [carry (car chunks)] [acc '()])
        (if (null? remaining)
          (reverse acc)
          (let* ([lines (split-many (car remaining) "\n")]
                 [fields (if (pair? lines) (car lines) "")]
                 [rest-lines (if (pair? lines) (cdr lines) '())]
                 [parts (split-many fields fs)])
            (loop (cdr remaining)
              (string-join rest-lines "\n")
              (if (>= (length parts) 4)
                (cons (hash 'graph carry
                       'hash
                       (trim (list-ref parts 0))
                       'author
                       (trim (list-ref parts 1))
                       'subject
                       (trim (list-ref parts 2))
                       'decoration
                       (trim (list-ref parts 3)))
                  acc)
                acc))))))))

(define (git-recent-commits dir [count #false])
  (if (git-has-commits? dir)
    (let* ([sep (string (integer->char 30))]
           [fs (string (integer->char 31))]
           [fmt (string-append sep "%h" fs "%an" fs "%s" fs "%d")]
           [args (append
                  (list "log" "--graph" "--date-order" "--all" "--decorate")
                  (if count
                    (list (string-append "-n" (number->string count)))
                    '())
                  (list (string-append "--format=" fmt)))]
           [res (git-exec dir args)])
      (if (hash-ref res 'ok)
        (parse-log-graph (hash-ref res 'stdout) sep fs)
        '()))
    '()))

(define (replace-once text old new)
  (let ([old-len (string-length old)]
        [len (string-length text)])
    (let loop ([i 0])
      (if (> (+ i old-len) len)
        text
        (if (string=? (substring text i (+ i old-len)) old)
          (string-append (substring text 0 i)
            new
            (substring text (+ i old-len) len))
          (loop (+ i 1)))))))

(define (string-contains? text needle)
  (let ([needle-len (string-length needle)]
        [len (string-length text)])
    (and (> needle-len 0)
      (let loop ([i 0])
        (cond
          [(> (+ i needle-len) len) #false]
          [(string=? (substring text i (+ i needle-len)) needle) #true]
          [else (loop (+ i 1))])))))

(define (commit-graph-lines commit)
  (let ([graph (hash-ref commit 'graph)])
    (if (string=? graph "")
      '()
      (split-many graph "\n"))))

;; Pull the first useful branch name out of a `git log --decorate` string.
(define (ref-part-name part)
  (let ([p (trim part)])
    (cond
      [(starts-with? p "HEAD -> ")
        (trim (substring p 8 (string-length p)))]
      [(or (string=? p "") (starts-with? p "tag: ")) #false]
      [(starts-with? p "origin/")
        (substring p 7 (string-length p))]
      [else p])))

(define (branch-from-decoration decoration)
  (let* ([len (string-length decoration)]
         [inner (if (and (> len 1) (char=? (string-ref decoration 0) #\())
                 (substring decoration 1 (- len 1))
                 decoration)]
         [parts (split-many inner ",")])
    (let loop ([remaining parts] [fallback ""])
      (if (null? remaining)
        fallback
        (let* ([part (trim (car remaining))]
               [name (ref-part-name part)])
          (if (and name (starts-with? part "HEAD -> "))
            name
            (loop (cdr remaining)
              (if (and name (string=? fallback "")) name fallback))))))))

(define (decoration-display decoration)
  (if (string=? decoration "")
    ""
    (let ([name (branch-from-decoration decoration)])
      (if (string=? name "")
        (string-append " " decoration)
        (string-append "  ← " name)))))

;; Render every commit as an `o` node, with explicit `|`, `|\` and `| |`
;; rails. Commit metadata stays aligned on the node row.
(define (commits-display-lines commits)
  (define (prepend-rails rails acc)
    (if (null? rails)
      acc
      (prepend-rails (cdr rails) (cons (trim (car rails)) acc))))
  (let loop ([remaining commits] [acc '()])
    (if (null? remaining)
      (reverse acc)
      (let* ([commit (car remaining)]
             [lines (commit-graph-lines commit)]
             [prior (all-but-last lines)]
             [node-raw (if (null? lines) "o" (car (reverse lines)))]
             [node-line (replace-once (trim node-raw) "*" "o")]
             [decoration (hash-ref commit 'decoration)]
             [node-text (string-append
                         node-line
                         " "
                         (hash-ref commit 'hash)
                         " "
                         (hash-ref commit 'author)
                         (string (integer->char 160))
                         (hash-ref commit 'subject)
                         (if (string=? decoration "")
                           ""
                           (decoration-display decoration)))]
             [with-rails (prepend-rails prior acc)])
        (loop (cdr remaining) (cons node-text with-rails))))))

(define (commit-display-lines commit)
  (commits-display-lines (list commit)))

;; Branches with ahead/behind counts, upstream and last commit metadata.
(define (git-branch-list dir)
  (let* ([fs (string (integer->char 31))]
         [fmt (string-append "%(refname:short)" fs "%(HEAD)" fs
               "%(upstream:short)"
               fs
               "%(objectname:short)"
               fs
               "%(subject)")]
         [res (git-exec dir
               (list "for-each-ref" (string-append "--format=" fmt) "refs/heads"))])
    (if (not (hash-ref res 'ok))
      '()
      (let loop ([lines (filter (lambda (l) (> (string-length l) 0))
                         (split-many (hash-ref res 'stdout) "\n"))]
                 [acc '()])
        (if (null? lines)
          (reverse acc)
          (let ([parts (split-many (car lines) fs)])
            (if (< (length parts) 5)
              (loop (cdr lines) acc)
              (let* ([name (list-ref parts 0)]
                     [current? (string=? (trim (list-ref parts 1)) "*")]
                     [upstream-raw (trim (list-ref parts 2))]
                     [upstream (if (string=? upstream-raw "") #false upstream-raw)]
                     [counts
                       (if upstream
                         (let ([cr (git-exec dir
                                    (list "rev-list" "--left-right" "--count"
                                      (string-append name "..." upstream)))])
                           (if (hash-ref cr 'ok)
                             (let* ([nums (split-whitespace
                                           (trim (hash-ref cr 'stdout)))]
                                    [ahead (if (pair? nums)
                                            (xit-string->number (car nums))
                                            0)]
                                    [behind (if (> (length nums) 1)
                                             (xit-string->number (list-ref nums 1))
                                             0)])
                               (cons ahead behind))
                             (cons 0 0)))
                         (cons 0 0))]
                     [ahead (car counts)]
                     [behind (cdr counts)]
                     [status
                       (cond
                         [(not upstream) "local"]
                         [(and (= ahead 0) (= behind 0)) "up to date"]
                         [(and (> ahead 0) (> behind 0)) "diverged"]
                         [(> behind 0) "need pull"]
                         [else "need push"])]
                     [branch
                       (hash 'name name
                         'current
                         current?
                         'upstream
                         upstream
                         'ahead
                         ahead
                         'behind
                         behind
                         'status
                         status
                         'hash
                         (trim (list-ref parts 3))
                         'subject
                         (trim (list-ref parts 4)))])
                (loop (cdr lines) (cons branch acc))))))))))

(define (git-branch-create! dir name [start #false])
  (if (string=? (trim name) "")
    (hash 'success #false 'message "Branch name cannot be empty")
    (let ([res (if start
                (git-exec dir (list "switch" "-c" name start))
                (git-exec dir (list "switch" "-c" name)))])
      (if (hash-ref res 'ok)
        (hash 'success #true
          'message
          (string-append "Created and switched to branch: " name))
        (hash 'success #false 'message (hash-ref res 'stderr))))))

(define (git-branch-checkout! dir name)
  (let ([branch (hash-ref (git-head-info dir) 'branch)])
    (if (string=? branch name)
      (hash 'success #true 'message (string-append "Already on branch: " name))
      (let ([res (git-exec dir (list "switch" "--" name))])
        (if (hash-ref res 'ok)
          (hash 'success #true
            'message
            (string-append "Switched to branch: " name))
          (hash 'success #false 'message (hash-ref res 'stderr)))))))

(define (git-branch-delete! dir name)
  (let ([branch (hash-ref (git-head-info dir) 'branch)])
    (if (string=? branch name)
      (hash 'success #false 'message "Cannot delete the current branch")
      (let ([res (git-exec dir (list "branch" "-D" "--" name))])
        (if (hash-ref res 'ok)
          (hash 'success #true 'message (string-append "Deleted branch: " name))
          (hash 'success #false 'message (hash-ref res 'stderr)))))))

(define (git-branch-merge! dir name)
  (let ([res (git-exec dir (list "merge" "--no-edit" name))]
        [conflicts? (not (null? (hash-ref (git-status-entries dir) 'unmerged)))])
    (cond
      [conflicts?
        (hash 'success #true 'conflicts #true
          'message
          (string-append "Merge conflicts while merging " name))]
      [(hash-ref res 'ok)
        (hash 'success #true 'conflicts #false
          'message
          (string-append "Merged branch: " name))]
      [else
        (hash 'success #false 'conflicts #false
          'message
          (hash-ref res 'stderr))])))

(define (git-branch-diff dir current selected)
  (let ([res (git-exec dir (list "diff" (string-append current "..." selected)))])
    (hash-ref res 'stdout)))

; Render the Head line consistently in every xit buffer.
(define (head-display head-info)
  (let ([branch (hash-ref head-info 'branch)]
        [upstream (hash-ref head-info 'upstream)]
        [ahead (hash-ref head-info 'ahead)]
        [behind (hash-ref head-info 'behind)]
        [status (hash-ref head-info 'status)])
    (if upstream
      (string-append branch " → " upstream
        " ↑"
        (number->string ahead)
        " ↓"
        (number->string behind)
        " "
        status)
      (string-append branch " (" status ")"))))

;; Format the full interactive git status buffer
(define (format-status-buffer repo-dir head-info entries recent-commits show-help? [expanded-paths '()])
  (let* ([unmerged (hash-ref entries 'unmerged)]
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
    (emit! (string-append "Head:    " (head-display head-info)))
    (emit! (string-append "Repo:    " repo-dir))
    (emit! "")

    ;; Help or Keys banner
    (if show-help?
      (begin
        (emit! "Help (press '?' to hide):")
        (emit! "  s        Stage file/section, or every file in selection")
        (emit! "  u        Unstage file/section, or every file in selection")
        (emit! "  v/V/C-j  Select line(s), then s to stage, u to unstage, D to discard")
        (emit! "  D        Discard file/section/selection")
        (emit! "  ret/tab  Fold/unfold file diff (or show commit diff)")
        (emit! "  o        Open file in editor")
        (emit! "  :git-diff Show diff buffer (all selected files when a selection is active)")
        (emit! "  O        Resolve conflict using OURS version")
        (emit! "  T        Resolve conflict using THEIRS version")
        (emit! "  c        Open commit editor; :w writes and commits")
        (emit! "  C        Amend last commit")
        (emit! "  S        Stage all changes")
        (emit! "  U        Unstage all changes")
        (emit! "  P        Git push")
        (emit! "  p        Git pull")
        (emit! "  b        Open branch manager")
        (emit! "  r        Refresh status")
        (emit! "  :git-save Apply edited buffer to git")
        (emit! "  q        Close git buffer")
        (emit! ""))
      (begin
        (emit! "Keys:    [s] stage  [u] unstage  [D] discard  [b] branches  [ret] fold diff  [?] help")
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

    ;; Full commit graph
    (when (not (null? recent-commits))
      (emit! (string-append "Commit Graph (" (number->string (length recent-commits)) ")"))
      (for-each emit!
        (commits-display-lines recent-commits))
      (emit! ""))

    (string-join (reverse out-lines) "\n")))

;; Render the branch manager buffer with aligned columns.
(define (format-branch-buffer repo-dir head-info branches show-help?)
  (let* ([names (map (lambda (b) (hash-ref b 'name)) branches)]
         [upstreams (map (lambda (b) (or (hash-ref b 'upstream) "—")) branches)]
         [arrows (map (lambda (b)
                       (string-append "↑"
                         (number->string (hash-ref b 'ahead))
                         " ↓"
                         (number->string (hash-ref b 'behind))))
                  branches)]
         [statuses (map (lambda (b) (hash-ref b 'status)) branches)]
         [hashes (map (lambda (b) (hash-ref b 'hash)) branches)]
         [name-width (max-string-length names)]
         [upstream-width (max-string-length upstreams)]
         [arrow-width (max-string-length arrows)]
         [status-width (max-string-length statuses)]
         [hash-width (max-string-length hashes)]
         [out-lines '()])
    (define (emit! line)
      (set! out-lines (cons line out-lines)))

    (emit! (string-append "Head:    " (head-display head-info)))
    (emit! (string-append "Repo:    " repo-dir))
    (emit! "")
    (if show-help?
      (begin
        (emit! "Keys:    [ret] checkout  [tab] diff  [c] create  [M] merge")
        (emit! "Keys:    [D] delete  [g] graph  [p] pull  [P] push")
        (emit! "Keys:    [r] refresh  [q] close  [?] hide help"))
      (emit! "Keys:    [ret] checkout  [tab] diff  [c] create  [D] delete  [M] merge  [g] graph  [?] help"))
    (emit! "")
    (emit! (string-append "Branches (" (number->string (length branches)) ")"))
    (let loop ([remaining branches]
               [remaining-names names]
               [remaining-upstreams upstreams]
               [remaining-arrows arrows]
               [remaining-statuses statuses]
               [remaining-hashes hashes])
      (unless (null? remaining)
        (emit!
          (string-append
            (if (hash-ref (car remaining) 'current) "* " "  ")
            (pad-right (car remaining-names) name-width)
            "  "
            (pad-right (car remaining-upstreams) upstream-width)
            "  "
            (pad-right (car remaining-arrows) arrow-width)
            "  "
            (pad-right (car remaining-statuses) status-width)
            "  "
            (pad-right (car remaining-hashes) hash-width)
            " "
            (hash-ref (car remaining) 'subject)))
        (loop (cdr remaining)
          (cdr remaining-names)
          (cdr remaining-upstreams)
          (cdr remaining-arrows)
          (cdr remaining-statuses)
          (cdr remaining-hashes))))
    (string-join (reverse out-lines) "\n")))

;; Render the full branch graph buffer.
(define (format-graph-buffer head-info commits)
  (let ([out-lines '()])
    (define (emit! line)
      (set! out-lines (cons line out-lines)))
    (emit! (string-append "Head:    " (head-display head-info)))
    (emit! "Keys:    [r] refresh  [q] close")
    (emit! "")
    (emit! "Branch Graph")
    (for-each emit!
      (commits-display-lines commits))
    (string-join (reverse out-lines) "\n")))

;; Branch name from a rendered branch line. Git branch names contain no spaces.
(define (parse-branch-line line)
  (if (or (starts-with? line "* ") (starts-with? line "  "))
    (let ([parts (split-whitespace
                  (substring line 2 (string-length line)))])
      (if (pair? parts) (car parts) #false))
    #false))

;; Entry lines are always "<marker><status>  <path>", where <marker> is "> ",
;; "v " or two spaces. Slice by fixed offsets instead of split-whitespace so
;; paths with spaces (including leading/trailing spaces) stay byte-exact.
(define (entry-status-text line)
  (if (< (string-length line) 2)
    ""
    (let ([parts (split-whitespace (substring line 2 (string-length line)))])
      (if (null? parts) "" (car parts)))))

(define (entry-path-from-line line)
  (let ([start (+ 2 (string-length (entry-status-text line)) 2)])
    (if (<= (string-length line) start)
      ""
      (substring line start (string-length line)))))

;; Parse line target from buffer lines and 0-indexed line number
(define (parse-line-target lines line-n)
  (if (or (< line-n 0) (>= line-n (length lines)))
    (hash 'type 'none)
    (let ([line (list-ref lines line-n)])
      (define (entry-from section)
        (let ([status (entry-status-text line)]
              [raw-path (entry-path-from-line line)])
          (hash 'type 'entry
            'section
            section
            'status
            status
            'path
            raw-path
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
        [(or (starts-with? line "Recent Commits (")
            (starts-with? line "Commit Graph ("))
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
        [(or (starts-with? line "  ")
            (starts-with? line "o")
            (starts-with? line "|"))
          (let ([c-hash (commit-hash-from-line line)])
            (if c-hash
              (hash 'type 'commit
                'hash
                c-hash
                'subject
                (commit-subject-from-line line))
              (hash 'type 'none)))]
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
              (let ([res (git-exec dir (list "add" "--" (git-pathspec path)))])
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
                        (git-exec dir (list "restore" "--staged" "--" (git-pathspec path)))
                        (git-exec dir (list "rm" "--cached" "-q" "--" (git-pathspec path))))])
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
                (let ([res (git-exec dir (list "add" "--" (git-pathspec path)))])
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
                            (git-exec dir (list "restore" "--staged" "--" (git-pathspec path)))
                            (git-exec dir (list "rm" "--cached" "-q" "--" (git-pathspec path))))])
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
              (let ([res (git-exec dir (list "restore" "--" (git-pathspec path)))])
                (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Discarded changes in: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
            [(eq? sec 'untracked)
              (let ([res (git-exec dir (list "clean" "-f" "-d" "--" (git-pathspec path)))])
                (if (hash-ref res 'ok)
                  (hash 'success #true 'message (string-append "Deleted untracked file: " path))
                  (hash 'success #false 'message (hash-ref res 'stderr))))]
            [(eq? sec 'staged)
              (let* ([_ (if (git-has-commits? dir)
                         (git-exec dir (list "restore" "--staged" "--" (git-pathspec path)))
                         (git-exec dir (list "rm" "--cached" "-q" "--" (git-pathspec path))))]
                     [res (git-exec dir (list "restore" "--" (git-pathspec path)))])
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
              (let ([res (git-exec dir (list "diff" "--staged" "--" (git-pathspec path)))])
                (hash-ref res 'stdout))]
            [(eq? sec 'unstaged)
              (let ([res (git-exec dir (list "diff" "--" (git-pathspec path)))])
                (hash-ref res 'stdout))]
            [(eq? sec 'unmerged)
              (let ([res (git-exec dir (list "diff" "--" (git-pathspec path)))])
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
  (let ([res1 (git-exec dir (list "checkout" "--ours" "--" (git-pathspec path)))])
    (if (hash-ref res1 'ok)
      (let ([res2 (git-exec dir (list "add" "--" (git-pathspec path)))])
        (if (hash-ref res2 'ok)
          (hash 'success #true 'message (string-append "Resolved (OURS): " path))
          (hash 'success #false 'message (hash-ref res2 'stderr))))
      (hash 'success #false 'message (hash-ref res1 'stderr)))))

;; Resolve conflict using THEIRS version and stage
(define (git-resolve-theirs! dir path)
  (let ([res1 (git-exec dir (list "checkout" "--theirs" "--" (git-pathspec path)))])
    (if (hash-ref res1 'ok)
      (let ([res2 (git-exec dir (list "add" "--" (git-pathspec path)))])
        (if (hash-ref res2 'ok)
          (hash 'success #true 'message (string-append "Resolved (THEIRS): " path))
          (hash 'success #false 'message (hash-ref res2 'stderr))))
      (hash 'success #false 'message (hash-ref res1 'stderr)))))

;; Extract entry path from a line. Fold markers and diff bodies are ignored;
;; entry paths are returned exactly as displayed, including spaces.
(define (extract-entry-path line)
  (if (or (starts-with? line "    ")
       (not (or (starts-with? line "> ")
             (starts-with? line "v ")
             (starts-with? line "  "))))
    #false
    (entry-path-from-line line)))

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
          [(or (starts-with? line "Recent Commits (")
              (starts-with? line "Commit Graph ("))
            (set! cur-sec 'recent-commits)]
          [(and (> (string-length line) 0)
              (not (starts-with? line "  "))
              (not (starts-with? line "o"))
              (not (starts-with? line "|"))
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

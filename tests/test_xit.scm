;; tests/test_xit.scm — Test suite for xit-core

(require "../xit-core.scm")

(define test-passed 0)
(define test-failed 0)

(define (assert-true label condition)
  (if condition
      (begin
        (set! test-passed (+ test-passed 1))
        (displayln (string-append "  [PASS] " label)))
      (begin
        (set! test-failed (+ test-failed 1))
        (displayln (string-append "  [FAIL] " label)))))

(define (assert-equal label actual expected)
  (if (equal? actual expected)
      (begin
        (set! test-passed (+ test-passed 1))
        (displayln (string-append "  [PASS] " label)))
      (begin
        (set! test-failed (+ test-failed 1))
        (displayln (string-append "  [FAIL] " label
                                  " (expected: " (to-string expected)
                                  ", got: " (to-string actual) ")")))))

(displayln "=== Running xit-core tests ===")

;; Test 1: Branch header parsing
(displayln "\n1. Branch header parsing tests:")
(let ([res1 (parse-branch-header "## No commits yet on main")])
  (assert-equal "No commits branch" (hash-ref res1 'branch) "main")
  (assert-equal "No commits status" (hash-ref res1 'status) "No commits yet"))

(let ([res2 (parse-branch-header "## main...origin/main [ahead 1, behind 2]")])
  (assert-equal "Tracking branch" (hash-ref res2 'branch) "main")
  (assert-equal "Tracking upstream" (hash-ref res2 'upstream) "origin/main")
  (assert-true "Tracking status contains ahead" (string-contains? (hash-ref res2 'status) "ahead 1")))

(let ([res3 (parse-branch-header "## feature...origin/feature")])
  (assert-equal "Up to date branch" (hash-ref res3 'branch) "feature")
  (assert-true "Up to date status" (string-contains? (hash-ref res3 'status) "up to date")))

;; Test 2: Porcelain status parsing
(displayln "\n2. Porcelain status parsing tests:")
(let* ([sample " M unstaged.rs\nM  staged.rs\nMM both.rs\nA  new.rs\nD  deleted.rs\n?? untracked.txt\nUU conflicted.txt\nR  old.txt -> new.txt\n"]
       [parsed (parse-porcelain-status sample)])
  (assert-equal "Staged count" (length (hash-ref parsed 'staged)) 5)
  (assert-equal "Unstaged count" (length (hash-ref parsed 'unstaged)) 2)
  (assert-equal "Untracked count" (length (hash-ref parsed 'untracked)) 1)
  (assert-equal "Unmerged count" (length (hash-ref parsed 'unmerged)) 1)
  (assert-equal "Untracked file" (car (hash-ref parsed 'untracked)) "untracked.txt")
  (assert-equal "Unmerged file" (cdr (car (hash-ref parsed 'unmerged))) "conflicted.txt"))

;; Test 3: Status buffer formatting
(displayln "\n3. Status buffer formatting tests:")
(let* ([head (hash 'branch "main" 'status "local branch" 'upstream #false 'ahead 0 'behind 0)]
       [entries (hash 'staged '(("M" . "staged.txt"))
                      'unstaged '(("M" . "unstaged.txt"))
                      'untracked '("untracked.txt")
                      'unmerged '())]
       [commits '(("a1b2c3d" . "initial commit"))]
       [buf-text (format-status-buffer "/path/to/repo" head entries commits #false)])
  (assert-true "Buffer contains Head" (string-contains? buf-text "Head:    main"))
  (assert-true "Buffer contains Staged (1)" (string-contains? buf-text "Staged (1)"))
  (assert-true "Buffer contains Unstaged (1)" (string-contains? buf-text "Unstaged (1)"))
  (assert-true "Buffer contains Untracked (1)" (string-contains? buf-text "Untracked (1)"))
  (assert-true "Buffer contains Recent Commits" (string-contains? buf-text "Recent Commits (1)")))

;; Test 4: Line target parsing
(displayln "\n4. Line target parsing tests:")
(let* ([lines (list
               "Head:    main (local branch)"
               "Repo:    /repo"
               ""
               "Keys:    [s] stage  [u] unstage ..."
               ""
               "Unstaged (1)"
               "  M  src/lib.rs"
               ""
               "Staged (1)"
               "  A  src/new.rs"
               ""
               "Untracked (1)"
               "  ?  notes.txt"
               ""
               "Recent Commits (1)"
               "  abc1234 feat: first commit")]
       [t-unstaged-hdr (parse-line-target lines 5)]
       [t-unstaged-ent (parse-line-target lines 6)]
       [t-staged-hdr   (parse-line-target lines 8)]
       [t-staged-ent   (parse-line-target lines 9)]
       [t-untracked-ent(parse-line-target lines 12)]
       [t-commit       (parse-line-target lines 15)])
  (assert-equal "Unstaged header type" (hash-ref t-unstaged-hdr 'type) 'section-header)
  (assert-equal "Unstaged header sec"  (hash-ref t-unstaged-hdr 'section) 'unstaged)
  (assert-equal "Unstaged entry type"   (hash-ref t-unstaged-ent 'type) 'entry)
  (assert-equal "Unstaged entry path"   (hash-ref t-unstaged-ent 'path) "src/lib.rs")
  (assert-equal "Staged entry path"     (hash-ref t-staged-ent 'path) "src/new.rs")
  (assert-equal "Untracked entry path"  (hash-ref t-untracked-ent 'path) "notes.txt")
  (assert-equal "Commit target hash"    (hash-ref t-commit 'hash) "abc1234"))

;; Test 5: Buffer edit / save actions (oil style)
(displayln "\n5. Buffer edit save action calculation tests:")
(let* ([orig (hash 'staged '("s1.txt")
                   'unstaged '("u1.txt" "u2.txt")
                   'untracked '("t1.txt" "t2.txt"))]
       [curr (hash 'staged '("s1.txt" "u1.txt")
                   'unstaged '()
                   'untracked '("t1.txt"))]
       [actions (calculate-save-actions orig curr)])
  (assert-equal "To stage" (hash-ref actions 'stage) '("u1.txt"))
  (assert-equal "To unstage" (hash-ref actions 'unstage) '())
  (assert-equal "To discard" (hash-ref actions 'discard) '("u2.txt"))
  (assert-equal "To clean" (hash-ref actions 'clean) '("t2.txt")))

(define (run-rm-rf! path)
  (let ([p (~> (command "rm" (list "-rf" path))
               with-stdout-piped with-stderr-piped spawn-process)])
    (when (Ok? p)
      (let* ([child (Ok->value p)]
             [out-p (child-stdout child)])
        (when out-p (read-port-to-string out-p))))))

;; Test 6: Live git operations in temporary repo
(displayln "\n6. Live Git operations in temporary repository:")
(define td "/tmp/xit_test_live_repo")
(run-rm-rf! td)
(git-exec "/tmp" (list "init" "-b" "main" td))

(assert-true "Repo detected" (git-repo? td))
(assert-true "No commits yet" (not (git-has-commits? td)))

;; Create and stage untracked file
(let ([p (path-join td "file1.txt")])
  (when (path-exists? p) (delete-file! p))
  (call-with-output-file p
    (lambda (out) (display "hello world\n" out))))

(let ([st (git-status-entries td)])
  (assert-equal "Untracked count before stage" (length (hash-ref st 'untracked)) 1))

(let* ([target (hash 'type 'entry 'section 'untracked 'path "file1.txt" 'status "?")]
       [res (git-stage-target! td target)])
  (assert-true "Stage untracked ok" (hash-ref res 'success)))

(let ([st (git-status-entries td)])
  (assert-equal "Staged count after stage" (length (hash-ref st 'staged)) 1))

;; Unstage before initial commit
(let* ([target (hash 'type 'entry 'section 'staged 'path "file1.txt" 'status "A" 'raw-path "file1.txt")]
       [res (git-unstage-target! td target)])
  (assert-true "Unstage in empty repo ok" (hash-ref res 'success)))

;; Stage all and commit
(let ([res (git-stage-all! td)])
  (assert-true "Stage all ok" (hash-ref res 'success)))

(let ([res (git-commit! td "Initial commit")])
  (assert-true "Commit ok" (hash-ref res 'success)))

(assert-true "Has commits after commit" (git-has-commits? td))

;; Modify file (unstaged)
(let ([p (path-join td "file1.txt")])
  (when (path-exists? p) (delete-file! p))
  (call-with-output-file p
    (lambda (out) (display "hello world modified\n" out))))

(let ([st (git-status-entries td)])
  (assert-equal "Unstaged count after edit" (length (hash-ref st 'unstaged)) 1))

;; Diff unstaged
(let* ([target (hash 'type 'entry 'section 'unstaged 'path "file1.txt" 'status "M")]
       [diff (git-diff-target td target)])
  (assert-true "Diff contains 'modified'" (string-contains? diff "modified")))

;; Stage, unstage, discard
(let* ([target (hash 'type 'entry 'section 'unstaged 'path "file1.txt" 'status "M")]
       [res (git-stage-target! td target)])
  (assert-true "Stage modified file ok" (hash-ref res 'success)))

(let* ([target (hash 'type 'entry 'section 'staged 'path "file1.txt" 'status "M" 'raw-path "file1.txt")]
       [res (git-unstage-target! td target)])
  (assert-true "Unstage modified file ok" (hash-ref res 'success)))

(let* ([target (hash 'type 'entry 'section 'unstaged 'path "file1.txt" 'status "M")]
       [res (git-discard-target! td target)])
  (assert-true "Discard modified file ok" (hash-ref res 'success)))

(let ([st (git-status-entries td)])
  (assert-equal "Unstaged count after discard" (length (hash-ref st 'unstaged)) 0))

;; Test 7: Merge conflict resolution
(displayln "\n7. Conflict resolution tests:")
(git-exec td '("checkout" "-b" "feat-branch"))
(let ([p (path-join td "file1.txt")])
  (when (path-exists? p) (delete-file! p))
  (call-with-output-file p
    (lambda (out) (display "feature branch line\n" out))))
(git-exec td '("commit" "-am" "feat change"))

(git-exec td '("checkout" "main"))
(let ([p (path-join td "file1.txt")])
  (when (path-exists? p) (delete-file! p))
  (call-with-output-file p
    (lambda (out) (display "main branch line\n" out))))
(git-exec td '("commit" "-am" "main change"))

;; Trigger merge conflict
(git-exec td '("merge" "feat-branch"))

(let ([st (git-status-entries td)])
  (assert-equal "Unmerged count during conflict" (length (hash-ref st 'unmerged)) 1))

;; Resolve conflict with THEIRS
(let ([res (git-resolve-theirs! td "file1.txt")])
  (assert-true "Resolve conflict with THEIRS ok" (hash-ref res 'success)))

(let ([st (git-status-entries td)])
  (assert-equal "Unmerged count after resolve" (length (hash-ref st 'unmerged)) 0)
  (assert-equal "Staged count after resolve" (length (hash-ref st 'staged)) 1))

;; Test 8: Batch stage/unstage (selection operations)
(displayln "\n8. Batch stage/unstage tests:")
(define bd "/tmp/xit_test_batch_repo")
(run-rm-rf! bd)
(git-exec "/tmp" (list "init" "-b" "main" bd))
(for-each
  (lambda (name)
    (let ([p (path-join bd name)])
      (when (path-exists? p) (delete-file! p))
      (call-with-output-file p
        (lambda (out) (display "one\n" out)))))
  '("a.txt" "b.txt" "c.txt"))
(git-exec bd (list "add" "-A"))
(git-exec bd (list "commit" "-m" "init"))

(for-each
  (lambda (name)
    (let ([p (path-join bd name)])
      (when (path-exists? p) (delete-file! p))
      (call-with-output-file p
        (lambda (out) (display "two\n" out)))))
  '("a.txt" "b.txt"))
(for-each
  (lambda (name)
    (let ([p (path-join bd name)])
      (when (path-exists? p) (delete-file! p))
      (call-with-output-file p
        (lambda (out) (display "new\n" out)))))
  '("d.txt" "e.txt"))

(let* ([targets (list (hash 'type 'entry 'section 'unstaged 'path "a.txt")
                      (hash 'type 'entry 'section 'unstaged 'path "b.txt")
                      (hash 'type 'entry 'section 'untracked 'path "d.txt")
                      (hash 'type 'entry 'section 'untracked 'path "e.txt")
                      (hash 'type 'entry 'section 'unstaged 'path "a.txt")
                      (hash 'type 'section-header 'section 'unstaged))]
        [res (git-stage-targets! bd targets)])
  (assert-true "Batch stage ok" (hash-ref res 'success))
  (assert-equal "Batch stage count" (hash-ref res 'count) 4)
  (assert-equal "Staged after batch"
                (length (hash-ref (git-status-entries bd) 'staged)) 4))

(let* ([targets (map (lambda (p)
                       (hash 'type 'entry 'section 'staged 'path p))
                     '("a.txt" "b.txt" "d.txt" "e.txt"))]
        [res (git-unstage-targets! bd targets)])
  (assert-true "Batch unstage ok" (hash-ref res 'success))
  (assert-equal "Batch unstage count" (hash-ref res 'count) 4)
  (let ([st (git-status-entries bd)])
    (assert-equal "Staged after batch unstage" (length (hash-ref st 'staged)) 0)
    (assert-equal "Unstaged after batch unstage" (length (hash-ref st 'unstaged)) 2)
    (assert-equal "Untracked after batch unstage" (length (hash-ref st 'untracked)) 2)))

(run-rm-rf! bd)

;; Clean up temporary repo
(run-rm-rf! td)

;; Summary
(displayln (string-append "\nTests complete: " (number->string test-passed)
                          " passed, " (number->string test-failed) " failed."))



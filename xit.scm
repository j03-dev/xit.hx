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

;; Git logic lives in xit-core.scm, next to this file in the same cog.
(require "xit-core.scm")

(provide Git
  git
  git-stage
  git-unstage
  git-stage-selection
  git-unstage-selection
  git-toggle-stage
  git-stage-all
  git-unstage-all
  git-discard
  git-open
  git-fold-toggle
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
  git-diff-selection
  git-branches
  git-branches-refresh
  git-branches-checkout
  git-branches-new
  git-branches-new-from
  git-branches-delete
  git-branches-merge
  git-branches-diff
  git-branches-help
  git-branches-close
  git-branch-graph
  git-graph-refresh
  git-graph-close
  git-save
  xit-info
  xit-error
  XIT-BUFFER-NAME
  XIT-COMMIT-BUFFER-NAME
  XIT-DIFF-BUFFER-NAME
  XIT-BRANCH-BUFFER-NAME
  XIT-GRAPH-BUFFER-NAME
  GIT-BUFFER-NAME
  GIT-COMMIT-BUFFER-NAME
  GIT-DIFF-BUFFER-NAME
  XIT-KEYMAPS
  XIT-COMMIT-KEYMAPS
  XIT-DIFF-KEYMAPS
  XIT-BRANCH-KEYMAPS
  XIT-GRAPH-KEYMAPS
  xit-install-buffer-keymap!)

;; Buffer names
(define XIT-BUFFER-NAME "*git*")
(define XIT-COMMIT-BUFFER-NAME "*git-commit*")
(define XIT-DIFF-BUFFER-NAME "*git-diff*")
(define XIT-BRANCH-BUFFER-NAME "*git-branches*")
(define XIT-GRAPH-BUFFER-NAME "*git-graph*")

;; Git's standard scissors line. Everything below it in the commit editor is a
;; display-only staged diff preview; Helix's git-commit grammar injects the diff
;; highlighter here, and xit truncates the message before passing it to git.
(define XIT-COMMIT-DIFF-SEPARATOR
  "# ------------------------ >8 ------------------------")

(define GIT-BUFFER-NAME XIT-BUFFER-NAME)
(define GIT-COMMIT-BUFFER-NAME XIT-COMMIT-BUFFER-NAME)
(define GIT-DIFF-BUFFER-NAME XIT-DIFF-BUFFER-NAME)
(define GIT-BRANCH-BUFFER-NAME XIT-BRANCH-BUFFER-NAME)
(define GIT-GRAPH-BUFFER-NAME XIT-GRAPH-BUFFER-NAME)

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
(define *xit-branch-doc-id* #false)
(define *xit-graph-doc-id* #false)
(define *xit-original-sections* #false)
(define *xit-show-help* #false)
(define *xit-branch-show-help* #false)
(define *xit-commit-amend?* #false)
(define *xit-commit-path* #false)
(define *xit-commit-finishing?* #false)
(define *xit-save-hook-registered?* #false)
(define *xit-remote-busy?* #false)
(define *xit-expanded-paths* '())

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

;; Reload every open file from disk after operations that change files outside
;; Helix (commit, abort/close, pull). Scratch buffers are ignored by Helix.
(define (xit-reload-all!)
  (with-handler (lambda (_) void)
    (helix.reload-all))
  void)

;; =============================================================================
;; Helix Editor Buffer Lifecycle
;; =============================================================================

(define (git-buffer-alive?)
  (and *xit-doc-id* (editor-doc-exists? *xit-doc-id*)))

(define (commit-buffer-alive?)
  (and *xit-commit-doc-id* (editor-doc-exists? *xit-commit-doc-id*)))

(define (diff-buffer-alive?)
  (and *xit-diff-doc-id* (editor-doc-exists? *xit-diff-doc-id*)))

(define (branch-buffer-alive?)
  (and *xit-branch-doc-id* (editor-doc-exists? *xit-branch-doc-id*)))

(define (graph-buffer-alive?)
  (and *xit-graph-doc-id* (editor-doc-exists? *xit-graph-doc-id*)))

(define (xit-focus-doc! doc-id)
  (when (and doc-id (editor-doc-exists? doc-id))
    (editor-switch-action! doc-id (Action/Replace)))
  void)

(define (xit-line-at lines n)
  (if (and (>= n 0) (< n (length lines)))
    (list-ref lines n)
    ""))

;; Refresh the status buffer content
(define (refresh-git-buffer! [target-line #false])
  (when (and *xit-dir* (git-buffer-alive?))
    (let* ([head-info (git-head-info *xit-dir*)]
           [entries (git-status-entries *xit-dir*)]
           [commits (git-recent-commits *xit-dir*)]
           [text-buf (format-status-buffer *xit-dir* head-info entries commits
                      *xit-show-help*
                      *xit-expanded-paths*)]
           [lines (split-many text-buf "\n")]
           [cur-line (or target-line (get-current-line-number))]
           [safe-line (max 0 (min cur-line (- (length lines) 1)))])
      ;; Store original state for buffer-editing diffing
      (set! *xit-original-sections*
        (hash 'staged (map cdr (hash-ref entries 'staged))
          'unstaged
          (map cdr (hash-ref entries 'unstaged))
          'untracked
          (hash-ref entries 'untracked)
          'unmerged
          (map cdr (hash-ref entries 'unmerged))))
      (select_all)
      (replace-selection-with text-buf)
      (collapse_selection)
      (helix.goto-line (+ safe-line 1)))))

; Refresh the branch manager buffer.
(define (refresh-branch-buffer! [target-line #false])
  (when (and *xit-dir* (branch-buffer-alive?))
    (let* ([head-info (git-head-info *xit-dir*)]
           [branches (git-branch-list *xit-dir*)]
           [text-buf (format-branch-buffer *xit-dir* head-info branches
                      *xit-branch-show-help*)]
           [lines (split-many text-buf "\n")]
           [cur-line (or target-line (get-current-line-number))]
           [safe-line (max 0 (min cur-line (- (length lines) 1)))])
      (select_all)
      (replace-selection-with text-buf)
      (collapse_selection)
      (helix.goto-line (+ safe-line 1)))))

;; Refresh the full commit graph buffer.
(define (refresh-graph-buffer! [target-line #false])
  (when (and *xit-dir* (graph-buffer-alive?))
    (let* ([head-info (git-head-info *xit-dir*)]
           [commits (git-recent-commits *xit-dir*)]
           [text-buf (format-graph-buffer head-info commits)]
           [lines (split-many text-buf "\n")]
           [cur-line (or target-line (get-current-line-number))]
           [safe-line (max 0 (min cur-line (- (length lines) 1)))])
      (select_all)
      (replace-selection-with text-buf)
      (collapse_selection)
      (helix.goto-line (+ safe-line 1)))))

;; Refresh every xit buffer that is currently open, restoring the original
;; focus afterwards so background operations do not yank the user away.
(define (xit-refresh-open-buffers!)
  (let ([original (with-handler (lambda (_) #false)
                   (editor->doc-id (editor-focus)))])
    (when (git-buffer-alive?)
      (xit-focus-doc! *xit-doc-id*)
      (refresh-git-buffer!))
    (when (branch-buffer-alive?)
      (xit-focus-doc! *xit-branch-doc-id*)
      (refresh-branch-buffer!))
    (when (graph-buffer-alive?)
      (xit-focus-doc! *xit-graph-doc-id*)
      (refresh-graph-buffer!))
    (when (and original (editor-doc-exists? original))
      (xit-focus-doc! original)))
  void)

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
            (xit-set-buffer-language! "xit" "git-commit"))
          (begin
            (helix.new)
            (enqueue-thread-local-callback
              (lambda ()
                (let* ([view-id (editor-focus)]
                       [doc-id (editor->doc-id view-id)])
                  (set! *xit-doc-id* doc-id)
                  (set-scratch-buffer-name! XIT-BUFFER-NAME)
                  (xit-install-buffer-keymap! XIT-BUFFER-NAME XIT-KEYMAPS)
                  (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-BUFFER-NAME)
                  (refresh-git-buffer! 4)
                  (xit-set-buffer-language! "xit" "git-commit"))))))))))

; Open or focus the branch manager buffer.
(define (open-branch-buffer-for-dir dir)
  (let* ([canonical (with-handler (lambda (_) dir) (canonicalize-path dir))]
         [repo-root (git-repo-root canonical)])
    (if (not repo-root)
      (xit-error (string-append "Not a git repository: " canonical))
      (begin
        (set! *xit-dir* repo-root)
        (if (branch-buffer-alive?)
          (begin
            (xit-focus-doc! *xit-branch-doc-id*)
            (refresh-branch-buffer!))
          (begin
            (helix.new)
            (enqueue-thread-local-callback
              (lambda ()
                (let* ([view-id (editor-focus)]
                       [doc-id (editor->doc-id view-id)])
                  (set! *xit-branch-doc-id* doc-id)
                  (set-scratch-buffer-name! XIT-BRANCH-BUFFER-NAME)
                  (xit-install-buffer-keymap! XIT-BRANCH-BUFFER-NAME XIT-BRANCH-KEYMAPS)
                  (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-BRANCH-BUFFER-NAME)
                  (refresh-branch-buffer! 7)
                  (xit-set-buffer-language! "xit" "git-commit"))))))))))

;; Open or focus the full branch graph buffer.
(define (open-graph-buffer-for-dir dir)
  (let* ([canonical (with-handler (lambda (_) dir) (canonicalize-path dir))]
         [repo-root (git-repo-root canonical)])
    (if (not repo-root)
      (xit-error (string-append "Not a git repository: " canonical))
      (begin
        (set! *xit-dir* repo-root)
        (if (graph-buffer-alive?)
          (begin
            (xit-focus-doc! *xit-graph-doc-id*)
            (refresh-graph-buffer!))
          (begin
            (helix.new)
            (enqueue-thread-local-callback
              (lambda ()
                (let* ([view-id (editor-focus)]
                       [doc-id (editor->doc-id view-id)])
                  (set! *xit-graph-doc-id* doc-id)
                  (set-scratch-buffer-name! XIT-GRAPH-BUFFER-NAME)
                  (xit-install-buffer-keymap! XIT-GRAPH-BUFFER-NAME XIT-GRAPH-KEYMAPS)
                  (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-GRAPH-BUFFER-NAME)
                  (refresh-graph-buffer! 4)
                  (xit-set-buffer-language! "xit" "git-commit"))))))))))

;; Branch name on the current line of *git-branches*.
(define (current-branch-buffer-name)
  (let ([fallback (if *xit-dir*
                   (hash-ref (git-head-info *xit-dir*) 'branch)
                   "HEAD")])
    (if (branch-buffer-alive?)
      (let* ([rope (editor->text *xit-branch-doc-id*)]
             [text (text.rope->string rope)]
             [lines (split-many text "\n")]
             [line (xit-line-at lines (get-current-line-number))]
             [name (parse-branch-line line)])
        (or name fallback))
      fallback)))

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
           [path (editor-document->path doc-id)]
           [dir (if path (parent-name path) (get-helix-cwd))])
      (open-git-for-dir dir))
    (let ([subcmd (car args)])
      (cond
        [(string=? subcmd "commit") (git-commit)]
        [(string=? subcmd "diff") (git-diff)]
        [(string=? subcmd "diff-selection") (git-diff-selection)]
        [(string=? subcmd "branches") (git-branches)]
        [(string=? subcmd "branch") (git-branches)]
        [(string=? subcmd "graph") (git-branch-graph)]
        [(string=? subcmd "push") (git-push)]
        [(string=? subcmd "pull") (git-pull)]
        [(string=? subcmd "status") (Git)]
        [(string=? subcmd "help") (git-help)]
        [(string=? subcmd "stage") (git-stage)]
        [(string=? subcmd "unstage") (git-unstage)]
        [(string=? subcmd "stage-selection") (git-stage-selection)]
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

;;@doc
;; Ask for confirmation before discarding the file/section under cursor, or
;; every selected file when a Helix selection spans multiple lines.
(define (git-discard)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let* ([line-numbers (current-selection-line-numbers)]
           [multi? (> (length line-numbers) 1)]
           [targets (if multi?
                     (targets-for-lines line-numbers)
                     (list (current-buffer-target)))]
           [entries (filter (lambda (target)
                             (eq? (hash-ref target 'type) 'entry))
                     targets)]
           [label (cond
                   [multi?
                     (string-append "Discard "
                       (number->string (length entries))
                       " selected file(s)? type y to confirm: ")]
                   [(pair? entries)
                     (string-append "Discard " (hash-ref (car entries) 'path)
                       "? type y to confirm: ")]
                   [else
                     "Discard this section? type y to confirm: "])]
           [confirmed? (lambda (answer)
                        (or (string=? answer "y") (string=? answer "Y")
                          (string=? answer "yes")
                          (string=? answer "YES")))])
      (if (and multi? (null? entries))
        (xit-error "Nothing to discard in selection")
        (push-component!
          (prompt label
            (lambda (answer)
              (when (confirmed? answer)
                (let* ([chosen (if multi? entries targets)]
                       [results (map (lambda (target)
                                      (git-discard-target! *xit-dir* target))
                                 chosen)]
                       [failed (filter (lambda (res)
                                        (not (hash-ref res 'success)))
                                results)])
                  (if (null? failed)
                    (begin
                      (xit-info
                        (if multi?
                          (string-append "Discarded "
                            (number->string (length results))
                            " file(s)")
                          (hash-ref (car results) 'message)))
                      (refresh-git-buffer!))
                    (xit-error (hash-ref (car failed) 'message)))))))))))
  void)

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
               [res (git-resolve-ours! *xit-dir* path)])
          (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (refresh-git-buffer!))
            (xit-error (hash-ref res 'message))))
        (xit-error "Cursor is not on an unmerged conflicted file")))))

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
               [res (git-resolve-theirs! *xit-dir* path)])
          (if (hash-ref res 'success)
            (begin
              (xit-info (hash-ref res 'message))
              (refresh-git-buffer!))
            (xit-error (hash-ref res 'message))))
        (xit-error "Cursor is not on an unmerged conflicted file")))))

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

;;@doc
;; Toggle the inline diff under the file under cursor (fold/unfold)
(define (git-fold-toggle)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let* ([target (current-buffer-target)]
           [line (get-current-line-number)]
           [type (hash-ref target 'type)])
      (cond
        [(eq? type 'entry)
          (let ([path (hash-ref target 'path)])
            (set! *xit-expanded-paths*
              (if (member path *xit-expanded-paths*)
                (filter (lambda (p) (not (string=? p path))) *xit-expanded-paths*)
                (cons path *xit-expanded-paths*)))
            (refresh-git-buffer! line))]
        [(eq? type 'commit) (git-diff)]
        [else (xit-info "No file under cursor to fold")]))))

;; Show diff text in the *git-diff* buffer, creating it on first use.
(define (xit-show-diff! diff-text)
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
                 [doc-id (editor->doc-id view-id)])
            (set! *xit-diff-doc-id* doc-id)
            (set-scratch-buffer-name! XIT-DIFF-BUFFER-NAME)
            (xit-install-buffer-keymap! XIT-DIFF-BUFFER-NAME XIT-DIFF-KEYMAPS)
            (helix.keymaps.#%add-reverse-mapping (doc-id->usize doc-id) XIT-DIFF-BUFFER-NAME)
            (insert_string diff-text)
            (helix.goto-line 1)
            (xit-set-buffer-language! "git-diff" "diff")))))))

;;@doc
;; Show the combined diff for every selected file in the git buffer
(define (git-diff-selection)
  (unless (git-buffer-alive?)
    (xit-error "No active git buffer"))
  (when (git-buffer-alive?)
    (let* ([targets (filter (lambda (t) (eq? (hash-ref t 'type) 'entry))
                     (current-selection-targets))]
           [chunks (filter (lambda (text) (not (string=? (trim text) "")))
                    (map (lambda (t) (git-diff-target *xit-dir* t)) targets))])
      (if (null? chunks)
        (xit-info "No file diff in selection")
        (xit-show-diff! (string-join chunks "\n"))))))

;;@doc
;; Show git diff for selected entries, the file under cursor, or the whole repo
(define (git-diff)
  (unless (git-buffer-alive?)
    (let ([cwd (get-helix-cwd)])
      (when (git-repo? cwd)
        (set! *xit-dir* (git-repo-root cwd)))))
  (unless *xit-dir*
    (xit-error "Not in a git repository"))
  (when *xit-dir*
    (if (and (git-buffer-alive?) (> (length (current-selection-line-numbers)) 1))
      (git-diff-selection)
      (let* ([target (if (git-buffer-alive?)
                      (current-buffer-target)
                      (hash 'type 'none))]
             [diff-text (git-diff-target *xit-dir* target)])
        (if (string=? (trim diff-text) "")
          (xit-info "No diff to display")
          (xit-show-diff! diff-text))))))

;@doc
;; Open or focus the branch manager buffer
(define (git-branches)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
    (open-branch-buffer-for-dir *xit-dir*)
    (xit-error "Not in a git repository")))

;;@doc
;; Refresh the branch manager buffer
(define (git-branches-refresh)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if (branch-buffer-alive?)
    (begin
      (refresh-branch-buffer!)
      (xit-info "Branches refreshed"))
    (xit-error "No active branch buffer")))

;;@doc
;; Check out the branch under the cursor
(define (git-branches-checkout)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (let* ([name (current-branch-buffer-name)]
           [res (git-branch-checkout! *xit-dir* name)])
      (if (hash-ref res 'success)
        (begin
          (xit-info (hash-ref res 'message))
          (xit-refresh-open-buffers!)
          (xit-reload-all!))
        (xit-error (hash-ref res 'message)))))
  void)

;;@doc
;; Create a new branch from HEAD and switch to it
(define (git-branches-new)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (push-component!
      (prompt "New branch name: "
        (lambda (name)
          (let ([res (git-branch-create! *xit-dir* name)])
            (if (hash-ref res 'success)
              (begin
                (xit-info (hash-ref res 'message))
                (xit-refresh-open-buffers!)
                (xit-reload-all!))
              (xit-error (hash-ref res 'message))))))))
  void)

;;@doc
;; Create a new branch from the selected branch and switch to it
(define (git-branches-new-from)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (let ([start (current-branch-buffer-name)])
      (push-component!
        (prompt (string-append "New branch from " start ": ")
          (lambda (name)
            (let ([res (git-branch-create! *xit-dir* name start)])
              (if (hash-ref res 'success)
                (begin
                  (xit-info (hash-ref res 'message))
                  (xit-refresh-open-buffers!)
                  (xit-reload-all!))
                (xit-error (hash-ref res 'message)))))))))
  void)

;;@doc
;; Safely delete the non-current branch under the cursor, after confirmation
(define (git-branches-delete)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (let ([name (current-branch-buffer-name)])
      (push-component!
        (prompt (string-append "Delete branch " name "? type y to confirm: ")
          (lambda (answer)
            (when (or (string=? answer "y") (string=? answer "Y")
                   (string=? answer "yes")
                   (string=? answer "YES"))
              (let ([res (git-branch-delete! *xit-dir* name)])
                (if (hash-ref res 'success)
                  (begin
                    (xit-info (hash-ref res 'message))
                    (xit-refresh-open-buffers!))
                  (xit-error (hash-ref res 'message))))))))))
  void)

;;@doc
;; Merge the branch under the cursor into the current branch
(define (git-branches-merge)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (let* ([name (current-branch-buffer-name)]
           [res (git-branch-merge! *xit-dir* name)])
      (cond
        [(not (hash-ref res 'success))
          (xit-error (hash-ref res 'message))]
        [(hash-ref res 'conflicts)
          (xit-error (hash-ref res 'message))
          (xit-refresh-open-buffers!)
          (xit-reload-all!)]
        [else
          (xit-info (hash-ref res 'message))
          (xit-refresh-open-buffers!)
          (xit-reload-all!)])))
  void)

;;@doc
;; Diff current branch against the branch under the cursor (current...selected)
(define (git-branches-diff)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (when *xit-dir*
    (let* ([current (hash-ref (git-head-info *xit-dir*) 'branch)]
           [selected (current-branch-buffer-name)]
           [diff-text (git-branch-diff *xit-dir* current selected)])
      (if (string=? selected current)
        (xit-info "Already on the selected branch")
        (if (string=? (trim diff-text) "")
          (xit-info "No differences between these branches")
          (xit-show-diff! diff-text)))))
  void)

;;@doc
;; Toggle branch manager help
(define (git-branches-help)
  (if (branch-buffer-alive?)
    (begin
      (set! *xit-branch-show-help* (not *xit-branch-show-help*))
      (refresh-branch-buffer!))
    (xit-error "No active branch buffer"))
  void)

;;@doc
;; Close the branch manager buffer
(define (git-branches-close)
  (when (branch-buffer-alive?)
    (xit-focus-doc! *xit-branch-doc-id*)
    (helix.buffer-close!)
    (set! *xit-branch-doc-id* #false))
  (xit-reload-all!)
  void)

;;@doc
;; Open or focus the full branch graph
(define (git-branch-graph)
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (if *xit-dir*
    (open-graph-buffer-for-dir *xit-dir*)
    (xit-error "Not in a git repository")))

;;@doc
;; Refresh the branch graph buffer
(define (git-graph-refresh)
  (if (graph-buffer-alive?)
    (begin
      (refresh-graph-buffer!)
      (xit-info "Graph refreshed"))
    (xit-error "No active graph buffer"))
  void)

;;@doc
;; Close the branch graph buffer
(define (git-graph-close)
  (when (graph-buffer-alive?)
    (xit-focus-doc! *xit-graph-doc-id*)
    (helix.buffer-close!)
    (set! *xit-graph-doc-id* #false))
  void)

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
         [staged-diff
           (trim
             (string-join
               (filter (lambda (text) (not (string=? (trim text) "")))
                 (map (lambda (item)
                       (git-diff-target *xit-dir*
                         (hash 'type 'entry 'section 'staged
                           'path
                           (extract-entry-path
                             (string-append "  " (car item) "  " (cdr item))))))
                   staged))
               "\n"))]
         [template
           (string-append
             (if (string=? prev-msg "") "" (string-append prev-msg "\n\n"))
             "\n"
             "# Please enter the commit message for your changes. Lines starting\n"
             "# with '#' will be ignored, and an empty message aborts the commit.\n"
             "# [:w] finishes the commit   [q] aborts\n"
             "# The staged diff below the separator is display-only.\n"
             "#\n"
             "# Changes to be committed:\n"
             (if (null? staged)
               "#   (none)\n"
               (string-join (map (lambda (p) (string-append "#   " (car p) "  " (cdr p))) staged) "\n"))
             "\n"
             (if (string=? staged-diff "")
               ""
               (string-append "\n" XIT-COMMIT-DIFF-SEPARATOR "\n" staged-diff "\n")))])
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
                   [doc-id (editor->doc-id view-id)])
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

;; Only the part above the diff separator is a commit message. Everything
;; below it is a display-only preview of the staged diff.
(define (commit-message-lines lines)
  (let loop ([remaining lines] [acc '()])
    (cond
      [(null? remaining) (reverse acc)]
      [(or (string=? (trim (car remaining)) XIT-COMMIT-DIFF-SEPARATOR)
          (starts-with? (car remaining) "diff --git "))
        (reverse acc)]
      [else (loop (cdr remaining) (cons (car remaining) acc))])))

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
             [lines (commit-message-lines (split-many text "\n"))]
             [content-lines (filter (lambda (l)
                                     (let ([t (trim l)])
                                       (not (or (starts-with? t "#") (string=? t "")))))
                             lines)]
             [final-msg (trim (string-join content-lines "\n"))])
        (if (string=? final-msg "")
          (begin
            (helix.buffer-close!)
            (xit-info "Commit aborted: empty commit message")
            (xit-reset-commit-state!)
            (xit-reload-all!))
          (let ([res (git-commit! *xit-dir* final-msg *xit-commit-amend?*)])
            (if (hash-ref res 'success)
              (begin
                (helix.buffer-close!)
                (let ([first-line (if (pair? content-lines) (car content-lines) "commit")])
                  (xit-info (string-append "Committed: " first-line)))
                (xit-refresh-open-buffers!)
                (xit-reset-commit-state!)
                (xit-reload-all!))
              (xit-error (string-append "Commit failed: " (hash-ref res 'message))))))))
    (set! *xit-commit-finishing?* #false))
  void)

;;@doc
;; Abort commit and close commit buffer
(define (git-commit-abort)
  (if (commit-buffer-alive?)
    (begin
      (helix.buffer-close!)
      (xit-reset-commit-state!)
      (xit-reload-all!)
      (xit-info "Commit cancelled"))
    (xit-error "No active commit buffer"))
  void)

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
          (when (git-buffer-alive?) (refresh-git-buffer!))
          (xit-reload-all!))
        (xit-error (hash-ref res 'message))))
    (xit-error "Not in a git repository")))

;; Run a blocking remote operation off the editor thread. `git-remote-async!`
;; calls back from its worker thread, so every Helix action (notifications and
;; buffer refresh) is marshalled back with `hx.with-context`.
(define (xit-remote! op-name start-msg done-msg args [reload-after? #false])
  (unless *xit-dir*
    (set! *xit-dir* (git-repo-root (get-helix-cwd))))
  (cond
    [(not *xit-dir*)
      (xit-error "Not in a git repository")]
    [*xit-remote-busy?*
      (xit-error (string-append op-name " is already running"))]
    [else
      (set! *xit-remote-busy?* #true)
      (xit-info start-msg)
      (git-remote-async!
        *xit-dir*
        args
        (lambda (res)
          (hx.with-context
            (lambda ()
              (set! *xit-remote-busy?* #false)
              (if (hash-ref res 'ok)
                (begin
                  (xit-info done-msg)
                  (xit-refresh-open-buffers!)
                  (when reload-after? (xit-reload-all!)))
                (let ([err (trim (hash-ref res 'stderr))]
                      [out (trim (hash-ref res 'stdout))])
                  (xit-error (if (string=? err "") out err))))))))
      void]))

;;@doc
;; Push current branch to remote without blocking Helix.
(define (git-push)
  (xit-remote! "Push" "Pushing..." "Push done" '("push")))

;;@doc
;; Pull current branch from remote without blocking Helix.
(define (git-pull)
  (xit-remote! "Pull" "Pulling..." "Pull done" '("pull") #true))

;;@doc
;; Refresh the git status buffer
(define (git-refresh)
  (if (git-buffer-alive?)
    (begin
      (refresh-git-buffer!)
      (xit-info "Status refreshed"))
    (xit-error "No active git buffer")))

;;@doc
;; Toggle keybinding cheat sheet in git buffer
(define (git-help)
  (if (git-buffer-alive?)
    (begin
      (set! *xit-show-help* (not *xit-show-help*))
      (refresh-git-buffer!))
    (xit-error "No active git buffer")))

;;@doc
;; Close the active git buffer and reload files changed by git operations.
(define (git-close)
  (helix.buffer-close!)
  (xit-reload-all!))

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

;; =============================================================================
;; Keymap Definition Hashes (Configurable)
;; =============================================================================

;; The same bindings are installed for normal and select mode: Helix uses a
;; separate keymap once `v` starts a selection, so `s`, `u` and `D` must be
;; present in both for the selection workflow to work.
(define XIT-BUFFER-KEYS
  (hash
    "s"
    ":git-stage"
    "u"
    ":git-unstage"
    "D"
    ":git-discard"
    "ret"
    ":git-fold-toggle"
    "tab"
    ":git-fold-toggle"
    "o"
    ":git-open"
    "O"
    ":git-resolve-ours"
    "T"
    ":git-resolve-theirs"
    "c"
    ":git-commit"
    "C"
    ":git-commit-amend"
    "S"
    ":git-stage-all"
    "U"
    ":git-unstage-all"
    "P"
    ":git-push"
    "p"
    ":git-pull"
    "b"
    ":git-branches"
    "r"
    ":git-refresh"
    "q"
    ":git-close"
    "?"
    ":git-help"))

(define XIT-KEYMAPS
  (hash "normal" XIT-BUFFER-KEYS "select" XIT-BUFFER-KEYS))

(define XIT-BRANCH-BUFFER-KEYS
  (hash
    "ret"
    ":git-branches-checkout"
    "tab"
    ":git-branches-diff"
    "n"
    ":git-branches-new"
    "N"
    ":git-branches-new-from"
    "D"
    ":git-branches-delete"
    "m"
    ":git-branches-merge"
    "g"
    ":git-branch-graph"
    "p"
    ":git-pull"
    "P"
    ":git-push"
    "r"
    ":git-branches-refresh"
    "q"
    ":git-branches-close"
    "?"
    ":git-branches-help"))

(define XIT-BRANCH-KEYMAPS
  (hash "normal" XIT-BRANCH-BUFFER-KEYS "select" XIT-BRANCH-BUFFER-KEYS))

(define XIT-GRAPH-BUFFER-KEYS
  (hash "r" ":git-graph-refresh" "q" ":git-graph-close"))

(define XIT-GRAPH-KEYMAPS
  (hash "normal" XIT-GRAPH-BUFFER-KEYS "select" XIT-GRAPH-BUFFER-KEYS))

;; Esc is deliberately left native here: repeated Esc presses collapse
;; selections and clear cursors, and must not abort the commit. Use q to abort.
(define XIT-COMMIT-KEYMAPS
  (hash
    "normal"
    (hash
      "q"
      ":git-commit-abort")))

(define XIT-DIFF-KEYMAPS
  (let ([keys (hash "q" ":git-close")])
    (hash "normal" keys "select" keys)))

;; Git-like commit: :w on the commit editor saves the message file and commits.
(define (xit-on-document-saved! doc-id)
  (when (and *xit-commit-doc-id* (equal? doc-id *xit-commit-doc-id*))
    (git-commit-finish))
  void)

(unless *xit-save-hook-registered?*
  (set! *xit-save-hook-registered?* #true)
  (register-hook 'document-saved xit-on-document-saved!))

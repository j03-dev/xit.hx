;; xit.hx status buffer highlights

(head_line)
@keyword
(repo_line)
@string.special.path
(keys_line)
@comment
(help_line)
@comment
(message_line)
@comment

;; Section headers
(section_unmerged_header)
@diff.minus
(section_unstaged_header)
@diff.minus
(section_staged_header)
@diff.plus
(section_untracked_header)
@string.special.path
(section_recent_commits_header)
@markup.heading

;; Status letters
(status_added)
@diff.plus
(status_copied)
@diff.plus
(status_deleted)
@diff.minus
(status_modified)
@diff.delta
(status_renamed)
@diff.delta.moved
(status_unmerged)
@error
(status_untracked)
@string.special.path

;; Paths get the color of their section.
(section_unmerged (entry (path) @error))
(section_unstaged (entry (path) @diff.minus))
(section_staged (entry (path) @diff.plus))
(section_untracked (entry (path) @string.special.path))

;; Inline folded diff bodies under a file entry: added lines green, removed
;; lines red, unchanged context lines left uncolored.
(diff_add)
@diff.plus
(diff_del)
@diff.minus

;; Recent commits: hashes use a distinct capture from subjects (usually blue)
;; so they stand out instead of sharing the yellow heading color.
(commit_hash)
@function
(section_recent_commits (commit (commit_subject) @markup.heading))

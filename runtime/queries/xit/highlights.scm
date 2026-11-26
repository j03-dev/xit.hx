;; xit.hx status, branch and graph buffer highlights

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
(section_commit_graph_header)
@markup.heading
(section_branches_header)
@markup.heading
(section_graph_header)
@markup.heading

;; Status letters. The whole status field is captured first as a fallback so
;; the M keeps its diff color even if the parser recovers from an inline diff.
(git_status)
@diff.delta
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

;; Branches.
(branch_line)
@variable

;; Inline folded diff bodies under a file entry: added lines green, removed
;; lines red, unchanged context lines left uncolored.
(diff_add)
@diff.plus
(diff_del)
@diff.minus

;; Commits: graph glyphs, hashes, authors, subjects and branch decorations each
;; use a distinct capture. The graph sits after the author, and non-breaking
;; spaces keep the columns visibly separated while colors stay independent.
(graph_prefix)
@keyword
(commit_hash)
@function
(commit (commit_author) @type)
(commit (commit_subject) @string)
(decoration_branch)
@diff.plus

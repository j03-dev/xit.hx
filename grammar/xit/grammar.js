module.exports = grammar({
  name: "xit",

  // Newlines only separate lines; leading spaces are significant because xit
  // uses two-space indentation for file, branch and commit entries.
  extras: $ => ["\n"],

  rules: {
    source_file: $ =>
      repeat(
        choice(
          $.head_line,
          $.repo_line,
          $.keys_line,
          $.help_line,
          $.section_unmerged,
          $.section_unstaged,
          $.section_staged,
          $.section_untracked,
          $.section_recent_commits_header,
          $.section_commit_graph_header,
          $.section_branches_header,
          $.section_graph_header,
          $.commit,
          $.graph_rail_line,
          $.branch_line,
          $.diff_line,
          $.message_line
        )
      ),

    head_line: $ => token(prec(2, /Head:[^\n\r]*/)),
    repo_line: $ => token(prec(2, /Repo:[^\n\r]*/)),
    keys_line: $ => token(prec(2, /Keys:[^\n\r]*/)),

    help_line: $ =>
      token(
        prec(
          2,
          /  (o[ \t]{6,}|(:git-save)[ \t]{1,}|(s|u|v\/V\/C-j|d|ret\/tab|D|O|T|c|C|S|U|P|p|b|r|q)[ \t]{2,})[^\n\r]*/
        )
      ),

    section_unmerged: $ => seq($.section_unmerged_header, repeat($.entry)),
    section_unstaged: $ => seq($.section_unstaged_header, repeat($.entry)),
    section_staged: $ => seq($.section_staged_header, repeat($.entry)),
    section_untracked: $ => seq($.section_untracked_header, repeat($.entry)),
    section_unmerged_header: $ => token(/Unmerged \([0-9]+\)/),
    section_unstaged_header: $ => token(/Unstaged \([0-9]+\)/),
    section_staged_header: $ => token(/Staged \([0-9]+\)/),
    section_untracked_header: $ => token(/Untracked \([0-9]+\)/),
    section_recent_commits_header: $ => token(/Recent Commits \([0-9]+\)/),
    section_commit_graph_header: $ => token(/Commit Graph \([0-9]+\)/),
    section_branches_header: $ => token(/Branches \([0-9]+\)/),
    section_graph_header: $ => token(/Branch Graph/),

    entry: $ =>
      seq(
        choice(/> /, /v /),
        field("status", $.git_status),
        /[ ]{2}/,
        field("path", $.path)
      ),

    git_status: $ =>
      choice(
        $.status_unmerged,
        $.status_added,
        $.status_copied,
        $.status_deleted,
        $.status_modified,
        $.status_renamed,
        $.status_untracked
      ),

    status_unmerged: () => /(UU|UA|AU|UD|DU|AA|DD|U)/,
    status_added: () => /A/,
    status_copied: () => /C/,
    status_deleted: () => /D/,
    status_modified: () => /M/,
    status_renamed: () => /R/,
    status_untracked: () => /\?/,

    path: () => token(/[^\n\r]+/),

    diff_line: $ => choice($.diff_add, $.diff_del, $.diff_context),

    diff_add: () => token(prec(3, /[ ]{4}\+[^\n\r]*/)),
    diff_del: () => token(prec(3, /[ ]{4}-[^\n\r]*/)),
    diff_context: () => token(prec(2, /[ ]{4}[^\n\r]*/)),

    commit: $ =>
      seq(
        field("graph", $.graph_prefix),
        field("hash", $.commit_hash),
        /[ ]/,
        field("author", $.commit_author),
        field("subject", $.commit_subject)
      ),

    graph_rail_line: $ => field("graph", $.graph_prefix),

    graph_prefix: () => token(/[*o|\\\/ ]+/),
    commit_hash: () => token(/[0-9a-f]{7,40}/),
    commit_author: () => token(/[^\u00A0\n\r]+\u00A0/),
    commit_subject: () => token(/[^\n\r]+/),

    branch_line: () =>
      token(prec(3, /(\*|  )[^\n\r]* ↑[0-9]+ ↓[0-9]+ [^\n\r]*/)),

    message_line: () => token(prec(-1, /[^ \n\r][^\n\r]*/)),
  },
});

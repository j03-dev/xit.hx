module.exports = grammar({
  name: "xit",

  // Newlines only separate lines; leading spaces are significant because xit
  // uses two-space indentation for file and commit entries.
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
          $.section_recent_commits,
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
          /  (s|u|v\/V\/C-j|d|ret\/tab|o|D|O|T|c|C|S|U|P|p|r|:git-save|q)[ \t]{2,}[^\n\r]*/
        )
      ),

    section_unmerged: $ => seq($.section_unmerged_header, repeat($.entry)),
    section_unstaged: $ => seq($.section_unstaged_header, repeat($.entry)),
    section_staged: $ => seq($.section_staged_header, repeat($.entry)),
    section_untracked: $ => seq($.section_untracked_header, repeat($.entry)),
    section_recent_commits: $ =>
      seq($.section_recent_commits_header, repeat($.commit)),

    section_unmerged_header: $ => token(/Unmerged \([0-9]+\)/),
    section_unstaged_header: $ => token(/Unstaged \([0-9]+\)/),
    section_staged_header: $ => token(/Staged \([0-9]+\)/),
    section_untracked_header: $ => token(/Untracked \([0-9]+\)/),
    section_recent_commits_header: $ => token(/Recent Commits \([0-9]+\)/),

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
        /[ ]{2}/,
        field("hash", $.commit_hash),
        /[ ]{2}/,
        field("subject", $.commit_subject)
      ),

    commit_hash: () => token(/[0-9a-f]{7,40}/),
    commit_subject: () => token(/[^\n\r]+/),

    message_line: () => token(prec(-1, /[^ \n\r][^\n\r]*/)),
  },
});

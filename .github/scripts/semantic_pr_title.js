// Proposes a Conventional Commits PR title. semantic-release reads the squash
// commit, so a PR without a valid title doesn't trigger a release.
//
// Matches the header pattern of semantic-release's default angular preset,
// which doesn't parse "feat!:". Breaking changes need a "BREAKING CHANGE:"
// footer added to the squash commit message at merge time.
//
// Used by .github/workflows/pr_title.yml. Returns null when the title is
// already valid or no type can be inferred; the title check then decides.

// Angular commit types (https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md)
// plus "chore", which release and dependency automation already use.
const TYPES = ["build", "ci", "docs", "feat", "fix", "perf", "refactor", "test", "revert", "chore"];

const ALIASES = { feature: "feat", bug: "fix", bugfix: "fix", hotfix: "fix", doc: "docs", tests: "test" };

// Higher-impact types win when commits disagree, so the release isn't undersized.
const PRECEDENCE = ["feat", "fix", "perf", "revert"];

const VALID = new RegExp(`^(${TYPES.join("|")})(\\([^()\\r\\n]+\\))?: \\S`);

// Headers with an unknown type ("style: x", "WIP: x") or a breaking "!" ("feat!: x",
// which would be released as non-breaking) are left to a human.
const HEADER_LIKE = /^[A-Za-z]+(\([^()\r\n]+\))?!?\s*:/;

function toType(word) {
  const lower = word.toLowerCase();
  const type = ALIASES[lower] || lower;
  return TYPES.includes(type) ? type : null;
}

// "Chore: x", "Fix(auth) - x", "[feat] x", "Chore/parallelize x", "Fix flaky test"
function fromTitlePrefix(title) {
  const unbracketed = title.replace(/^\[([A-Za-z]+)(\([^()\r\n]+\))?\]\s*/, "$1$2: ");
  const match = unbracketed.match(/^([A-Za-z]+)(\([^()\r\n]+\))?\s*(:|\/|\s-\s|\s)\s*(\S.*)$/);
  if (!match) return null;

  const [, word, scope = "", separator, subject] = match;
  const type = toType(word);
  if (!type) return null;

  // A bare leading word is only trusted for "fix"; "Build x" or "Test x" are usually verbs.
  if (separator.trim() === "" && type !== "fix") return null;

  return `${type}${scope.toLowerCase()}: ${subject}`;
}

// "fix/presence-diff", "feat-tenant-cache", "user/fix-presence-diff"
function fromBranch(branch) {
  const prefixes = [branch.match(/^([A-Za-z]+)[/_-]/), branch.match(/^[^/]+\/([A-Za-z]+)[/_-]/)];
  return prefixes.map((match) => match && toType(match[1])).find(Boolean) || null;
}

function fromCommits(subjects) {
  const types = subjects
    .map((subject) => subject.match(VALID))
    .filter(Boolean)
    .map((match) => match[1]);

  return PRECEDENCE.find((type) => types.includes(type)) || types[0] || null;
}

function proposeTitle({ title, branch = "", commitSubjects = [] }) {
  const trimmed = title.trim();
  if (VALID.test(trimmed)) return null;

  const fixed = fromTitlePrefix(trimmed);
  if (fixed) return fixed;
  if (HEADER_LIKE.test(trimmed)) return null;

  const type = fromBranch(branch) || fromCommits(commitSubjects);
  return type ? `${type}: ${trimmed}` : null;
}

module.exports = { proposeTitle };

# Publish to ashare

GitHub Action: a CI step that publishes a report (tests, Lighthouse, an agent's write-up) to [ashare.net](https://ashare.net) and posts the link as a comment in the pull request. A reviewer opens the link, selects text and comments; no account needed.

A composite action on bash, curl and jq, with no Node build: jq and curl are already on GitHub runners, `ubuntu-latest` included. It lives in the public repository [Magir/ashare-action](https://github.com/Magir/ashare-action) and is used as `uses: Magir/ashare-action@v1`: `v1` is the stable tag, `@main` the latest commit.

## Example

`report.yml` in `.github/workflows/` of your repository:

```yaml
name: Report
on: pull_request

permissions:
  contents: read
  pull-requests: write  # the comment with the link

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: npx playwright test --reporter=html  # anything that writes a report to a file
      - uses: Magir/ashare-action@v1
        id: ashare
        with:
          file: playwright-report/index.html
          title: E2E report
          api-key: ${{ secrets.ASHARE_API_KEY }}
      - run: echo "Report ${{ steps.ashare.outputs.url }} v${{ steps.ashare.outputs.version }}"
```

The key: sign in at [ashare.net/login](https://ashare.net/login), create a key on `/me/api` and put it in the repository secret `ASHARE_API_KEY` (Settings → Secrets and variables → Actions).

The pull request gets a comment:

> Report: E2E report → https://ashare.net/a/AbC123xyz789 (v1)

The next push to the same pull request publishes v2 of the same document and edits that same comment instead of adding another.

## Inputs

| Input | Default | What it does |
|---|---|---|
| `file` | — | Path to the report. The extension picks the format: `.html`/`.htm`, `.md`/`.markdown`, `.zip` for a site of several files: `index.html` at the root of the archive or in its single folder, styles, images, more pages, up to 200 files and 25 MB |
| `title` | `''` | Document title. Empty: ashare takes `<title>` from HTML or the first heading from Markdown |
| `api-key` | — | Your ashare key, from a secret |
| `base-url` | `https://ashare.net` | The ashare server |
| `visibility` | `public` | `public`: anyone with the link; `private`: only the author and the access list; `company`: also everyone in the author's organization on ashare (members and emails on its domains; without an organization the server answers 400). Any other value fails before publishing. ashare itself makes new documents private, the action makes them public: a CI report is for the reviewers of the pull request, who may have no account. `''`: do not pass it; a new document takes the account default, an existing one keeps its visibility |
| `expires-in` | `''` | Link lifetime from now: `30m`, `24h`, `7d`. Every run extends it. Empty: the account default for a new document, untouched on an existing one |
| `artifact-id` | `''` | Update this document instead of creating a new one |
| `comment` | `true` | Post the link as a comment in the pull request |
| `github-token` | `${{ github.token }}` | Token for the comment; needs `pull-requests: write` |

Outputs: `url`, `id`, `version`.

## How the action finds the same document

1. `artifact-id` is set: a new version of that document. If it does not exist or belongs to someone else, the step fails.
2. Otherwise, in a pull request with `comment: true`, the action looks for its own earlier comment in that pull request. Its body carries a hidden line `<!-- ashare id=<id> file=<file> -->`: the id comes from there, the action publishes a new version and edits the comment (PATCH). Each `file` gets its own comment and its own document, so two reports in one pull request do not interfere. If the document was deleted on ashare since then, the action publishes a new one and edits the same comment.
3. Otherwise it publishes a new document.

Only comments from the token's account are considered: with `GITHUB_TOKEN` that is `github-actions[bot]`, with a personal access token its owner. In a public repository anyone can comment on a pull request, and a planted line with someone else's id would otherwise make CI overwrite another document.

Updates go without `base_version`: a CI report is rebuilt every time, the last run wins. Two runs of the same pull request at once may land out of order; `concurrency: report-${{ github.ref }}` on the job prevents that.

## Without a pull request

On `push` and other events without a pull request the comment is skipped and the log says `comment: no pull request in this push event`. Without `artifact-id` every run then creates a new document. To keep a branch report at one link, publish it once and pass the id:

```yaml
on:
  push:
    branches: [main]
# …
      - uses: Magir/ashare-action@v1
        with:
          file: report.html
          api-key: ${{ secrets.ASHARE_API_KEY }}
          artifact-id: AbC123xyz789  # the id from the first run, output id
```

## Errors

Everything is printed as `::error::` in the step log and the step fails:

- `api-key is empty`: the secret is missing. GitHub does not pass secrets to pull requests from forks; skip such jobs with `if: github.event.pull_request.head.repo.full_name == github.repository`;
- `file must end with .html, .htm, .md, .markdown or .zip`, `file not found`, `visibility must be public, private, company or empty`;
- `ashare: HTTP <code>: <text>`: the server's answer: 401 wrong key, 404 no document with that `artifact-id`, 413 file over the limit, 429 the limit of a new account;
- `GitHub API … HTTP 403`: the token lacks `pull-requests: write`. The document is already published by then and the outputs are set.

## Running locally

`publish.sh` reads the inputs from the environment variables `FILE`, `TITLE`, `API_KEY`, `BASE_URL`, `VISIBILITY`, `EXPIRES_IN`, `ARTIFACT_ID`, `COMMENT`, `GITHUB_TOKEN`, and the context from the standard `GITHUB_API_URL`, `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH` and `GITHUB_OUTPUT` that the runner sets:

```bash
FILE=report.html API_KEY=<key> VISIBILITY=public bash publish.sh
```

## License

MIT, see [LICENSE](LICENSE).

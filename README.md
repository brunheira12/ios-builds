# ios-builds

GitHub Actions workflow that builds iOS apps and uploads them to TestFlight.
App configuration lives in repository secrets. Tool output goes to an encrypted log.
The public log shows step status and, only when a compile-only build fails, the
xcodebuild exit code plus sanitized compiler errors.

`permissions` stays empty. The job does not use `GITHUB_TOKEN` to read app source.

## Dispatch inputs

| Input | Default | Effect |
| --- | --- | --- |
| `app` | `APP1` | Slot `APP1`–`APP10`. `APP10` is the Origin slot. |
| `build_number` | required | `CFBundleVersion` for a signed build. Checked, and not written into the project, when `compile_only` is true. |
| `upload` | `true` | TestFlight upload. Ignored when `compile_only` is true. |
| `xcode` | empty | Xcode app name suffix. Empty keeps the runner default. |
| `compile_only` | `false` | Skip certificates, profiles, export, and TestFlight. `xcodebuild build` with `CODE_SIGNING_ALLOWED=NO`. |
| `compile_destination` | `ios` | Used only when `compile_only` is true: `ios` (generic iOS) or `simulator`. A watch-only native project uses watchOS. |

Signed steps for `compile_only: false` are unchanged: GitHub deploy-key checkout, manual distribution signing, watch and extension profiles, archive, export, and upload when `upload` is true.

## APP1–APP9

Leave `APPn_SOURCE` unset. The slot keeps `APPn_REPO`, `APPn_DEPLOY_KEY`, `APPn_SUBDIR`, `APPn_ENV`, and the profile secrets (`APPn_PROFILE_B64`, optional `APPn_WATCH_PROFILE_B64`, optional `APPn_EXT_PROFILE_B64`). Shared signing secrets are unchanged: `IOS_DIST_P12_B64`, `IOS_DIST_P12_PASSWORD`, `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_B64`, `LOG_PUBKEY`.

## APP10 and Origin

Origin stays the source of truth. The workflow does not mirror the repo into GitHub and does not upload source or a plaintext build log. The archive API (`GET /v1/origin/repos/{owner}/{repo}/tarball/{ref}`) is not used: that gzip has no gitlinks, so a submodule pin cannot be fetched or checked. Checkout is Git HTTPS with a short-lived installation token whose only requested scope is `repository:contents:read` ([Git HTTPS authentication](https://cursor.com/docs/api/origin/reference/git-https-authentication), [Create Installation Access Token](https://cursor.com/docs/api/origin/reference/create-installation-access-token)). The token is passed through a credential helper for `origin.cursor.com` only. It is not put in the remote URL, argv, or git config.

### First unsigned Super16 run

Do not dispatch until the Origin app below exists. Suggested inputs:

- `app`: `APP10`
- `build_number`: `1`
- `upload`: `false`
- `compile_only`: `true`
- `compile_destination`: `ios`
- `xcode`: empty

`compile_only` skips upload even if `upload` is left true. No ROM is launched, and the simulator is not booted.

Secrets (names only):

| Secret | Value shape |
| --- | --- |
| `APP10_SOURCE` | `origin` |
| `APP10_REPO` | `jefferson-brunheira/super16` |
| `APP10_REF` | Full 40-character commit SHA. A 7–40 hex prefix is also accepted and must match one commit on `APP10_BRANCH`. The known prefix is `9d4b832`. |
| `APP10_BRANCH` | Optional. Default `main`. Not `refs/heads/...`. |
| `APP10_VERIFY_PATH` | `Super16.xcodeproj` (comma-separated repo-root paths). The step fails if one is missing. |
| `APP10_REQUIRE_SUBMODULE` | `snes9x`. Fails unless a submodule path or URL contains that name and is checked out at the gitlink SHA. Clear it if Snes9x is vendored instead of a submodule, and add that directory to `APP10_VERIFY_PATH`. |
| `APP10_SCHEME` | Optional `Super16` when the project file has that name. |
| `APP10_SUBDIR` | Empty when the project is at the repo root. |
| `ORIGIN_APP_ID` | App id, `app_...`. |
| `ORIGIN_INSTALLATION_ID` | Installation id from the installation URL. |
| `ORIGIN_APP_PRIVATE_KEY` | PEM of the Ed25519 private key (`BEGIN PRIVATE KEY`). |
| `ORIGIN_REPOSITORY_ID` | Optional. Leave unset when the app is installed on this one repository. If set, use the `id` from Get Repo: live ids look like `r_…`, and the API examples look like `repo_…`. |

Not used for this compile-only run: `APP10_DEPLOY_KEY`, `APP10_PROFILE_B64`, `APP10_WATCH_PROFILE_B64`, `APP10_EXT_PROFILE_B64`, the distribution certificate, and the App Store Connect API key. `LOG_PUBKEY` is still required; the encrypted log artifact is the same as for signed builds.

### Create the Origin app

Follow [Build an Origin App](https://cursor.com/docs/origin/apps/build-app) and [Set up CloneKit in CI](https://cursor.com/docs/origin/clonekit-ci) for the JWT shape. This workflow does not call CloneKit.

1. `openssl genpkey -algorithm ED25519 -out origin-app-private.pem` and `openssl pkey -in origin-app-private.pem -pubout -out origin-app-public.pem`.
2. Create a private app at Origin app settings and register only the public key.
3. Install it on the owner of `jefferson-brunheira/super16`, selected repositories only, scope `repository:contents:read` only.
4. Copy the app id and the installation id (`/codebase/settings/apps/installations/{installationId}`) into the secrets above. Store the private PEM as `ORIGIN_APP_PRIVATE_KEY`.

The job signs an app JWT (`alg` EdDSA, `iss` and `kid` = app id, `aud` origin-apps, 15 minute lifetime) and exchanges it for an installation token. The token expires within 15 minutes and is minted at checkout. A usable token is the documented `oit_` string. A missing app, a non-200 response, or an HTTP 403 from an enforced team inbound IP allowlist fails the step. The public log then has the HTTP status, JSON key names, and (for a 200 body that is not a usable token) length and character-class flags. It does not include the token or the error message text. Personal namespaces have no inbound IP allowlist. A team allowlist that is enforced must admit the GitHub-hosted macOS runner, or checkout returns 403. Nothing in this repo bypasses that.

After checkout the encrypted log records the full commit SHA, each submodule path and gitlink SHA, and a `snes9x <sha>` line when a submodule matches. The public log does not include those values. On compile failure the public log adds `xcodebuild exit <status>` and diagnostic lines (`error:`, linker, `** BUILD FAILED **`) with runner paths removed. Source lines, tokens, and private keys are not printed there. The full transcript stays in the encrypted artifact `log-<run id>`.

## Tests

`bash tests/ios-build-workflow.test.sh` runs on Linux. It checks the signed step bodies, the Origin checkout against local git fixtures, JWT signing, token handling, and compile-only arguments. It does not call Origin or Xcode.

# GitHub PAT setup for deb2ipa

deb2ipa talks to api.github.com over HTTPS with a fine-grained personal access
token (PAT). The token is stored in the iOS Keychain (ThisDeviceOnly
accessibility) and is only ever sent as an Authorization header to
api.github.com.

## Creating the token

1. GitHub -> Settings -> Developer settings -> Personal access tokens ->
   Fine-grained tokens -> Generate new token.
2. Resource owner: yourself. Repository access: **Only select repositories**
   -> ddr-ai/deb2ipa.
3. Permissions:
   - **Contents: Read and write** (release assets; draft-release upload
     fallback for large debs)
   - **Actions: Read and write** (workflow dispatch, run status, logs)
   - **Metadata: Read-only** (mandatory, pre-selected)
4. Nothing else. No admin permissions, no classic scopes, no other
   repositories.
5. Set an expiration, generate, and copy the token (starts with github_pat_).

## Where it goes

- In the app (M6): Settings screen -> paste the PAT. It is saved to the
  Keychain and validated (GET /user plus the repository workflow list)
  before first use; 401s surface as an actionable error.
- For a manual live run on your Mac:

      cd app
      DEB2IPA_TOKEN="github_pat_..." swift test --filter HelloWorkflowLiveTests

  This dispatches the real hello-m3 workflow and polls it to completion -
  the M3 acceptance, end to end.

- In CI (optional): add a repository secret named DEB2IPA_TOKEN
  (Settings -> Secrets and variables -> Actions). The Tests workflow passes
  it to the test step, so HelloWorkflowLiveTests dispatches a real hello-m3
  run on every push. Without the secret the live test skips; the
  mock-transport suite still covers every code path.

## Notes

- The built-in GITHUB_TOKEN cannot be used for this: events created by
  GITHUB_TOKEN never start workflow runs (GitHub's recursion prevention).
- The token grants write access to this repository only. Treat it like a
  password; rotate it if it ever leaks.

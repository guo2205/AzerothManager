# Repository workflow

This is the source repository for 艾泽拉斯插件管家 (AzerothManager).
Remote: https://github.com/guo2205/AzerothManager.git

The user explicitly requests that every completed code update be committed and pushed to this repository. This authorization persists for routine updates.

- Check the working tree and remote state before changing code; preserve unrelated user changes.
- Run checks appropriate to the change. Core changes require `swift test`; UI or project changes require an Xcode build. Do not claim unexecuted checks passed.
- After a coherent update passes relevant checks, review the diff, commit with a clear message, and push the current branch to origin. Verify the remote commit and report the result.
- If command-line GitHub authentication is unavailable, use the connected GitHub tools to publish the reviewed update, then fetch and align the local branch with the verified remote commit. Preserve unpublished local commits on a backup branch before aligning; never discard uncommitted changes.
- Do not force-push or overwrite remote work. Reconcile incoming changes while preserving local work.
- This repository is public. Never commit API keys, credentials, personal application forms, local game data, backups, build caches, or private contact details. Check newly added files before publishing.
- If tests or the push fail, explain what remains unsynchronized. Do not claim synchronization succeeded.
- GitHub synchronization does not update files uploaded to ChatGPT Projects automatically.

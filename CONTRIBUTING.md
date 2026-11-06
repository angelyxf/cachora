# Contributing to Cachora

Start with a reproducible issue and disposable files. Never run a cleanup test against a real home directory, Downloads, Trash, credentials or model store.

```sh
python3 scripts/build-local-app.py --tests-only
python3 scripts/prepare-beta.py --check
```

Use `scripts/create-demo-workspace.py` to generate a marked workspace. The fixture app rejects an invalid workspace instead of falling back to real user data.

Keep the upstream MIT notice, include a test for a meaningful cleanup or update boundary change, and report which checks actually ran. Preserve both copies when a restore destination already exists. Do not make recovery or conflict protection conditional on payment.

Product metadata is centralized in `release/product.json`. Internal source directories, module names and historical author credits retain their PureMac names to keep the fork reviewable.

For a data-loss or path-validation issue, avoid posting private file contents publicly. Open a minimal issue describing the class of problem and request a private reporting channel before sharing sensitive details. No dedicated private security mailbox is configured yet.

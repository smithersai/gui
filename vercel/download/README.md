# download.smithers.sh

Tiny Vercel project that 302-redirects `download.smithers.sh/*` to the R2
release bucket (`pub-969210e77f5749a6999183cefd8ac46b.r2.dev`).

`smithers.sh` is on Vercel team `evmts`; this lives as a separate Vercel
project so the docs site (Mintlify) stays untouched.

## Deploy

```bash
bun scripts/deploy-download-redirect.ts
```

The release pipeline (`alchemy.run.ts`) calls this automatically, so the
redirect stays in sync with `vercel.json` on every `bun release`.

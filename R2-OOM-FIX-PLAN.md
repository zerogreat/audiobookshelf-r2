# Plan: Fix OOM crash-loop during library scan (post-R2-migration)

## Symptom

After the R2 migration went live (see `R2-MIGRATION-PLAN.md` in the old
`burgerlove-audiobooks` project — now superseded by this repo), the library only
showed 18-22 of the ~38 books in the R2 bucket, and a manual rescan appeared to run
for an hour without finishing.

## Diagnosis (confirmed via `fly logs -a burgerlove-books --no-tail`)

It is **not** a slow scan — it's an **out-of-memory crash loop**. Roughly 20 seconds
after the scan starts, the kernel OOM-killer kills `rclone`, then `node`, then the
**entire Fly machine reboots**:

```
[LibraryScanner] Starting library scan ... for Books
Out of memory: Killed process 668 (rclone) ... anon-rss:142972kB
WARNING: rclone died, remounting...
Out of memory: Killed process 649 (node) ... anon-rss:48360kB
INFO Process appears to have been OOM killed!
INFO Umounting /dev/vdc from /config
reboot: Restarting system
```

The machine comes back up, the scan resumes/restarts, gets a little further (hence
the slow creep from 18 → 22 books), then OOMs again. Repeat indefinitely — this is
why it "looked stuck" for an hour.

### Root cause

The Fly machine ([fly.toml](fly.toml)) is sized at **`shared-cpu-1x` / `512mb`
RAM** — the smallest practical option. During a scan, audiobookshelf spawns
`ffprobe` against every audio file to read duration/chapters/cover art. Combined
with `--vfs-cache-mode full` (the setting we deliberately chose in the R2 rewrite to
fix the earlier inode-instability "missing books" bug — see the old plan doc),
rclone downloads and caches whole files locally as they're read, holding sizeable
read-ahead buffers (`--buffer-size 64M`, `--vfs-read-chunk-size 128M` per open file).
rclone alone was already at 143 MB resident when the kernel started killing
processes — 512 MB total just isn't enough headroom for rclone + Node + several
concurrent `ffprobe` subprocesses + OS overhead.

This is a real tradeoff: `--vfs-cache-mode full` is what fixes the missing-books
bug, but it is meaningfully more memory-hungry than the old `minimal` mode. The fix
is **not** to revert that setting (it would reintroduce the original bug) — it's to
give the machine enough memory to support it.

## Fix (agreed: try 1 GB first, can go to 2 GB later if needed)

Two coordinated changes on the `audiobookshelf-r2` branch in
`M:\code\burgerlove\audiobookshelf-r2`:

### 1. `fly.toml` — bump VM memory

Fly lets you set `memory` independently of the CPU tier, so we keep
`shared-cpu-1x` (cheap CPU allocation) and just raise the RAM:

```toml
[[vm]]
  size = 'shared-cpu-1x'
  memory = '1gb'      # was '512mb'
```

- [ ] Edit `fly.toml`

### 2. `start.sh` — trim rclone's per-file memory footprint (safety margin)

Don't rely on raw VM size alone to paper over a hungry config — tune the mount
flags down slightly so there's real headroom even under load:

```diff
   rclone mount r2:${R2_BUCKET_NAME} /audiobooks \
     --allow-other \
     --vfs-cache-mode full \
     --cache-dir /config/rclone-cache \
     --vfs-cache-max-size 2G \
     --vfs-read-chunk-size 128M \
-    --buffer-size 64M \
+    --buffer-size 32M \
+    --transfers 2 \
     --dir-cache-time 72h \
     --poll-interval 30m \
     --low-level-retries 10 \
     --retries 5 \
     --daemon
```

(`--transfers 2` caps concurrent rclone downloads, which caps how many large
in-flight read buffers can exist simultaneously during a scan.)

- [ ] Edit `start.sh`

### 3. Commit, push, redeploy

```powershell
cd M:\code\burgerlove\audiobookshelf-r2
git add fly.toml start.sh
git commit -m "Bump VM to 1GB RAM and trim rclone memory footprint to fix OOM crash loop during scans"
git push origin audiobookshelf-r2
fly deploy --app burgerlove-books
```

- [ ] Commit + push + deploy

### 4. Verify the fix

- [ ] Watch `fly logs -a burgerlove-books --no-tail` (or live-tail) through a full
      library rescan — confirm **no** `Out of memory: Killed process` lines and
      **no** `reboot: Restarting system` lines
- [ ] In the UI, trigger a manual library rescan and let it run to completion
      (should take minutes, not hours, once it's not crash-looping)
- [ ] Confirm the book count matches the ~38 books actually in the R2 bucket
- [ ] Spot check: open a few of the newly-appeared books and confirm playback works
      (validates that `--vfs-cache-mode full` is actually serving file content
      correctly under the new memory ceiling)

## If 1 GB still isn't enough

`fly logs` will show the same OOM signature again, just perhaps later into the scan
(further book count progress before crashing). If so, bump again:

```toml
  memory = '2gb'
```
then repeat steps 3-4. (Cost difference between 1 GB and 2 GB on `shared-cpu-1x` is
on the order of a few dollars/month — check the Fly dashboard billing page for your
account's current rate.)

## Status

- [x] Diagnosed (this document)
- [ ] Fix applied
- [ ] Verified in production

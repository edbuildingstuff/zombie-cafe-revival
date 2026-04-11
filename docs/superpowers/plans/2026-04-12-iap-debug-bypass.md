# Legacy APK IAP Bypass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch `com/capcom/billing/SmurfsBilling.smali` so that when the native game launches the Activity (via the unchanged `ZombieCafeAndroid.BuyToxin` → `startActivity` path), the Activity immediately fakes a successful purchase by reading the `ItemName0` extra from the Intent, calling `ZombieCafeAndroid.boughtToxin(productID)`, and calling `finish()`. The game sees a normal Activity-swap cycle and the credited toxin without any billing roundtrip.

**Architecture:** Three smali methods in one file are rewritten. `onCreate(Bundle)` is shrunk from ~280 lines to ~30 lines of "read Intent extra, credit toxin, finish". `doFinish()` and `onDestroy()` are replaced with null-safe minimal versions because the `BillingService`/`e` fields they originally dereferenced are no longer initialized. `ZombieCafeAndroid.BuyToxin` is **not** touched — the native game's shopping state machine requires the full `startActivity` → `onPause` → Activity → `onResume` cycle to clear its "waiting for purchase" dim overlay, so we let `BuyToxin` launch `SmurfsBilling` exactly as the original did and only short-circuit the Activity's body.

**Tech Stack:** smali (apktool-decoded APK format), `apktool b` for reassembly, `jarsigner` for signing with the bundled `debug.keystore`, `adb` for installation and log capture, the existing `src/lib/cpp/libZombieCafeExtension.so` (unchanged).

**Environment gotchas** (from `docs/handoff.md`):
- Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival`
- Go: `/c/Program Files/Go/bin/go.exe` (not on PATH)
- `apktool`, `jarsigner` assumed on `PATH`
- `adb`: `/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe` (not on PATH in Git Bash)
- The game currently survives several minutes before hitting `Scudo: corrupted chunk header` aborts from pre-existing heap bugs — if the device test window is short, keep the verification sequence tight so the bypass can be confirmed before an unrelated crash terminates the session

**Commit policy:** The user asked to commit the spec, plan, and smali changes together at the end. Do NOT commit per task. The final task (Task 7) handles the single grouped commit covering all three files.

**Spec:** `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md`

---

## Task 1: Verify `BuyToxin`, `PurchaseAndroidToxin`, and `SmurfsBilling` baselines

**Files:**
- Read: `src/smali/com/capcom/zombiecafeandroid/ZombieCafeAndroid.smali`
- Read: `src/smali/com/capcom/zombiecafeandroid/CC_Android.smali`
- Read: `src/smali/com/capcom/billing/SmurfsBilling.smali`

Before editing, confirm that the code we're depending on hasn't drifted from what the spec assumes.

- [ ] **Step 1: Confirm `BuyToxin(I)V` still builds the Intent with `ItemName0` short-form product IDs**

Read `src/smali/com/capcom/zombiecafeandroid/ZombieCafeAndroid.smali` around line 3133. Confirm:

- `.method public BuyToxin(I)V` exists
- The Google path (`:cond_0` branch, roughly line 3231) builds an Intent targeting `com.capcom.billing.SmurfsBilling` and puts `ItemName0` as a short-form string (`zc_50_toxin_3`, `zc_125_toxin_2`, `zc_350_toxin_2`, `zc_800_toxin_2`, `zc_2000_toxin_2`) per slot before calling `startActivity(intent)`

If the Intent extra key has changed (e.g. renamed to `ProductID0` or similar) or the short-form values have been repackaged to include the `com.capcom.zombiecafeandroid.` prefix, Task 2's `Bundle.getString("ItemName0")` call and `boughtToxin(productID)` match logic both need to be adjusted.

- [ ] **Step 2: Confirm `boughtToxin(String)` still matches against short-form IDs and calls `PurchaseAndroidToxin`**

Read `src/smali/com/capcom/zombiecafeandroid/ZombieCafeAndroid.smali` around line 2515. Confirm:

- `.method public static boughtToxin(Ljava/lang/String;)V` exists
- Its switch matches against short-form IDs (`zc_50_toxin_3` etc.) via `String.matches(...)`
- Each case sets `purchaseAmount` and calls `invoke-static {...} PurchaseAndroidToxin(I)V`

This is the method the SmurfsBilling bypass will invoke from `onCreate`. If its signature or matching logic has changed, the bypass needs updating.

- [ ] **Step 3: Confirm `SmurfsBilling.onCreate`, `doFinish`, and `onDestroy` are all present and reference the `i` and `e` instance fields**

Read `src/smali/com/capcom/billing/SmurfsBilling.smali`. Confirm:

- `onCreate(Landroid/os/Bundle;)V` at line 432, `.locals 10` as first line of body
- `doFinish()V` at line 298, references `->i:Lcom/capcom/billing/e;` and `->e:Lcom/capcom/billing/BillingService;`
- `onDestroy()V` at line 757, same two field references

If the field names or types have changed, Task 3's null-safe replacements need to be re-derived so they preserve the methods' public contracts.

- [ ] **Step 4: Confirm `CC_Android.fromNative_BuyStuff(I)V` is still the only native-side caller of `BuyToxin`**

```bash
grep -n "BuyToxin" src/smali/ -r
```

Expected: a single match in `CC_Android.smali:125` (inside `fromNative_BuyStuff`) pointing at `ZombieCafeAndroid.BuyToxin(I)V`. Any additional caller means the scope analysis in the spec needs revisiting.

---

## Task 2: Replace `SmurfsBilling.onCreate` with the fake-success bypass

**Files:**
- Modify: `src/smali/com/capcom/billing/SmurfsBilling.smali` (method at line 432)

- [ ] **Step 1: Apply the edit**

Use the Edit tool to replace the entire original `onCreate(Landroid/os/Bundle;)V` body. `old_string` is everything from `.method public onCreate(Landroid/os/Bundle;)V` through the closing `.end method` (lines 432 – ~482, including the trailing `:array_0` fill-array-data block that the original used for the SimpleCursorAdapter binding).

`new_string` is:

```smali
.method public onCreate(Landroid/os/Bundle;)V
    .locals 2

    invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V

    const-string v0, "SmurfsBilling bypass"

    const-string v1, "onCreate - faking purchase success"

    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p0}, Lcom/capcom/billing/SmurfsBilling;->getIntent()Landroid/content/Intent;

    move-result-object v0

    if-eqz v0, :cond_0

    invoke-virtual {v0}, Landroid/content/Intent;->getExtras()Landroid/os/Bundle;

    move-result-object v0

    if-eqz v0, :cond_0

    const-string v1, "ItemName0"

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->getString(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    if-eqz v0, :cond_0

    const-string v1, "SmurfsBilling bypass"

    invoke-static {v1, v0}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    invoke-static {v0}, Lcom/capcom/zombiecafeandroid/ZombieCafeAndroid;->boughtToxin(Ljava/lang/String;)V

    :cond_0
    invoke-virtual {p0}, Lcom/capcom/billing/SmurfsBilling;->finish()V

    return-void
.end method
```

**Register allocation notes for reviewers:**
- `.locals 2` → v0, v1 are locals. `p0` (this) is v2, `p1` (savedInstanceState) is v3. `invoke-super {p0, p1}` passes {v2, v3} — both fit in the 4-bit register window the instruction requires.
- v0 is reused across three moves: Intent → Bundle → String, each move guarded by `if-eqz` → `:cond_0` fall-through to `finish()` if null.
- v1 is reused: tag string `"SmurfsBilling bypass"` → key string `"ItemName0"` → tag string again for the second log line.
- No `fill-array-data` is used, so the trailing `:array_0` block from the original is dropped entirely. No dangling label references.
- The method ends with `return-void` after `finish()`. The `:cond_0` label is the fall-through for any null-Intent/null-Bundle/null-productID path; it also calls `finish()` before returning, so the Activity always terminates cleanly.

- [ ] **Step 2: Confirm the edit was applied by re-reading the anchor lines**

Read `src/smali/com/capcom/billing/SmurfsBilling.smali` around line 432. Confirm:

- Line 432 is `.method public onCreate(Landroid/os/Bundle;)V`
- Line 433 is `.locals 2` (was `.locals 10` before the edit)
- The first substantive instruction after `invoke-super` is `const-string v0, "SmurfsBilling bypass"` — no `getExtras` / array iteration loop, no `setContentView`, no `BillingService` instantiation
- The method ends with `return-void` and `.end method` followed by the next method `onCreateDialog(I)V`

If the structure doesn't match, revert the edit and re-diagnose.

---

## Task 3: Replace `SmurfsBilling.doFinish` with a null-safe body

**Files:**
- Modify: `src/smali/com/capcom/billing/SmurfsBilling.smali` (method originally at line 298)

- [ ] **Step 1: Apply the edit**

`old_string`:

```smali
.method protected doFinish()V
    .locals 1

    iget-object v0, p0, Lcom/capcom/billing/SmurfsBilling;->i:Lcom/capcom/billing/e;

    invoke-virtual {v0}, Lcom/capcom/billing/e;->a()V

    iget-object v0, p0, Lcom/capcom/billing/SmurfsBilling;->e:Lcom/capcom/billing/BillingService;

    invoke-virtual {v0}, Lcom/capcom/billing/BillingService;->b()V

    invoke-virtual {p0}, Lcom/capcom/billing/SmurfsBilling;->finish()V

    return-void
.end method
```

`new_string`:

```smali
.method protected doFinish()V
    .locals 0

    invoke-virtual {p0}, Lcom/capcom/billing/SmurfsBilling;->finish()V

    return-void
.end method
```

`.locals 0` because no local registers are needed. `p0` alone is used and invoke-virtual accepts it in any register position.

---

## Task 4: Replace `SmurfsBilling.onDestroy` with a null-safe body

**Files:**
- Modify: `src/smali/com/capcom/billing/SmurfsBilling.smali` (method originally at line 757)

- [ ] **Step 1: Apply the edit**

`old_string`:

```smali
.method protected onDestroy()V
    .locals 2

    invoke-super {p0}, Landroid/app/Activity;->onDestroy()V

    iget-object v0, p0, Lcom/capcom/billing/SmurfsBilling;->i:Lcom/capcom/billing/e;

    invoke-virtual {v0}, Lcom/capcom/billing/e;->a()V

    iget-object v0, p0, Lcom/capcom/billing/SmurfsBilling;->e:Lcom/capcom/billing/BillingService;

    invoke-virtual {v0}, Lcom/capcom/billing/BillingService;->b()V

    const-string v0, "SmurfsBilling onDestroy()"

    const-string v1, "BillingService Unbind()"

    invoke-static {v0, v1}, Landroid/util/Log;->v(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method
```

`new_string`:

```smali
.method protected onDestroy()V
    .locals 0

    invoke-super {p0}, Landroid/app/Activity;->onDestroy()V

    return-void
.end method
```

Note: `onStop()` on `SmurfsBilling` is **not** touched. Its existing `iget-object v0, ... ->c:Lcom/capcom/billing/q;` reads a null field — harmless in Dalvik since the null is immediately discarded without being dereferenced — and its call to `doFinish()` goes to the null-safe replacement from Task 3.

---

## Task 5: Rebuild the APK and catch any smali syntax errors

**Files:**
- Build output: `build/` (gitignored)
- Build output: `build/out/out.apk` (gitignored)

- [ ] **Step 1: Run the Go build_tool to emit `build/`**

```bash
"/c/Program Files/Go/bin/go.exe" run ./tool/build_tool -i src/ -o build/
```

Expected: populated `build/` tree, including `build/smali/com/capcom/billing/SmurfsBilling.smali` identical in size/timestamp to `src/`. The Go tool passes smali through unchanged.

- [ ] **Step 2: Copy the pre-built `libZombieCafeExtension.so` into place**

```bash
cp src/lib/cpp/build/libZombieCafeExtension.so ./build/lib/armeabi/libZombieCafeExtension.so
```

- [ ] **Step 3: Run apktool build**

```bash
apktool b ./build -o ./build/out/out.apk
```

Expected: exit 0. `Smaling smali folder into classes.dex...` succeeds without syntax errors. The only expected warning is the pre-existing `W: ... AndroidManifest.xml:42: warn: unexpected element <adaptive-icon> found in <manifest>.` which is unrelated to this patch.

If apktool complains about `SmurfsBilling`:

1. **Missing label reference:** check that `:cond_0` is defined after the productID check and is the sole label reference. The original method had `:cond_1`/`:cond_2`/`:cond_3`/`:goto_0`/`:goto_1`/`:array_0` — all of those must be removed.
2. **Orphan data block:** the original `:array_0 .array-data 4 ... .end array-data` must be dropped since nothing references it in the new method.
3. **`.locals` too low:** verify the register count. The new onCreate uses v0, v1, and p0=v2, p1=v3. `.locals 2` is correct.

- [ ] **Step 4: Sign the APK**

```bash
jarsigner -sigalg SHA1withRSA -digestalg SHA1 -keystore debug.keystore -storepass zombiecafe ./build/out/out.apk alias_name
```

Expected: "jar signed." The SHA1 deprecation warnings are informational.

---

## Task 6: Install and verify on device

**Files:** None — runtime-only.

- [ ] **Step 1: Confirm `adb` sees the device**

```bash
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" devices
```

Expected: one device in `device` state.

- [ ] **Step 2: Install**

```bash
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" install -r ./build/out/out.apk
```

Expected: `Success`.

- [ ] **Step 3: Force-stop and relaunch**

The `install -r` command replaces the APK on disk but does not restart any running instance. Force-stop and relaunch so the patched APK is actually what loads:

```bash
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" shell am force-stop com.capcom.zombiecafeandroid && \
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" logcat -c && \
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" shell am start -n com.capcom.zombiecafeandroid/.ZombieCafeAndroid
```

- [ ] **Step 4: Reach the low-toxin slot picker**

This requires manual input from the device operator:

1. Wait for the game to reach gameplay (skip past title/loading)
2. Get the in-game toxin counter to a low value — either by already having a low save state, or by attempting to buy a chef that costs more than the current toxin
3. When the 5-slot picker opens, tap any slot

The slot picker is rendered by the native C++ game (confirmed via the `E BuyToxinDialog: initContents` tag visible in logcat when the picker opens), so there's no Java-side log to watch for when the picker itself appears.

- [ ] **Step 5: Verify the bypass fired**

After tapping a slot:

```bash
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" logcat -d | grep "SmurfsBilling bypass"
```

Expected: two lines per tap:
```
D SmurfsBilling bypass: onCreate - faking purchase success
D SmurfsBilling bypass: zc_<N>_toxin_<X>
```

Where `zc_<N>_toxin_<X>` is the short-form product ID corresponding to the tapped slot.

Also verify:

- **In-game HUD toxin counter** increases by the slot amount (50 / 125 / 350 / 800 / 2000)
- **No dim freeze overlay** — the game returns to normal gameplay immediately after the brief SmurfsBilling Activity flash
- **No `AndroidRuntime` or `DEBUG` crashes** during or after the tap

- [ ] **Step 6: Confirm no billing service activity**

```bash
"/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe" shell dumpsys activity services | grep -i billing
```

Expected: no match. If the grep matches, something is still dispatching intents at `com.capcom.billing.BillingService`, indicating the bypass didn't short-circuit early enough.

---

## Task 7: Commit spec, plan, and smali changes

**Files to stage:**
- `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` (new)
- `docs/superpowers/plans/2026-04-12-iap-debug-bypass.md` (new)
- `src/smali/com/capcom/billing/SmurfsBilling.smali` (modified — onCreate, doFinish, onDestroy)

Per the user's commit-style memory (`memory/feedback_commit_style.md`), this is one grouped commit, not split options.

- [ ] **Step 1: Confirm the working tree**

```bash
git status
```

Expected: three files listed (the two untracked markdown docs and the one modified smali file). `ZombieCafeAndroid.smali` should **not** be in the list — earlier iterations of this session patched it, but it was reverted in favor of the SmurfsBilling-only approach.

- [ ] **Step 2: Stage the three files explicitly**

```bash
git add \
  docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md \
  docs/superpowers/plans/2026-04-12-iap-debug-bypass.md \
  src/smali/com/capcom/billing/SmurfsBilling.smali
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
smali: bypass SmurfsBilling to fake toxin purchases without hitting Play

Replaces SmurfsBilling.onCreate with a minimal body that reads the
ItemName0 Intent extra, calls ZombieCafeAndroid.boughtToxin(productID)
to fire the normal success callback path, and calls finish(). Also
replaces SmurfsBilling.doFinish and SmurfsBilling.onDestroy with
null-safe bodies because the BillingService and purchase-DB fields are
no longer initialized in the bypass path.

BuyToxin stays unchanged so the full startActivity → onPause → child
Activity → onResume cycle fires, which is what clears the native
game's "waiting for purchase" dim overlay state. An earlier attempt
to patch BuyToxin directly credited the toxin but left the dim
overlay active until the user hit the Android back button; the
SmurfsBilling-only approach avoids that cosmetic wart.

This unblocks reaching late-game states for save-file fixture
extraction without a working Google Play Billing v1 backend (the
original billing API has been dead on modern Android for years). The
HUD toxin icon "store page" entry point remains broken — that's a
separate native-side WebView on a dead URL and is not addressed here.
See docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md
for the design and docs/superpowers/plans/2026-04-12-iap-debug-bypass.md
for the implementation plan.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git log --oneline -1 && git status
```

Expected: the new commit at HEAD, clean working tree.

---

## Rollback

Two layers:

**1. Full revert of this patch.** `git revert <commit-sha>` and rebuild per Task 5/6. Both the spec and plan stay in the repo as a record of the investigation even after revert — only the smali change is rolled back.

**2. Fallback to the alternative `BuyToxin` direct-call approach.** If on-device testing reveals the SmurfsBilling onCreate bypass is itself wrong in some way we haven't yet diagnosed (e.g. the `onPause`/`onResume` cycle isn't actually what clears the dim state), the spec's Findings section documents an alternative that *was* confirmed to credit toxin: patch `ZombieCafeAndroid.BuyToxin(I)V` to call `PurchaseAndroidToxin(amount)` directly on the render thread. The toxin is credited but the user has to dismiss a dim overlay via the Android back button. Accept the cosmetic wart as a fallback if a cleaner fix proves unreachable. The original `BuyToxin` method body is recoverable from git history.

## Out of scope — follow-up investigation

The HUD toxin icon in the game's main UI does not open any store page — tapping it plays a click sound and nothing else. This is a separate native-side code path, almost certainly a WebView loading a dead Capcom URL. Investigation deferred to a future session. See the "Open question: HUD toxin icon does not open any store page" section of the spec for the three candidate fix paths (logcat instrumentation, Ghidra, or accept the limitation).

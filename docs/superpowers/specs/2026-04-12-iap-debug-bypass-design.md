# Legacy APK IAP Bypass — Design

**Date:** 2026-04-12
**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Phases touched:** none — this is a quality-of-life patch to the legacy APK smali shell, unrelated to the Godot rewrite phase plan.

## Goal

Make the in-game toxin purchase flow instantly succeed without contacting Google Play. After this change, any time the native C++ game triggers the 5-slot toxin picker (e.g. when the player tries to buy a chef that costs more toxin than they have), tapping any slot credits the corresponding amount (50 / 125 / 350 / 800 / 2000) and returns the player to the game immediately with no dim/freeze interstitial and no billing service roundtrip. The goal is unblocking late-game content for fixture extraction, not preserving any fidelity to the original billing flow.

## Context

The legacy APK ships a Google Play Billing v1 integration (`com/capcom/billing/*.smali`, with a `BillingService`, `SmurfsBilling` Activity, and `BillingReceiver`). Google Play Billing v1 was deprecated in 2013 and has been non-functional on modern Android for years — any real purchase attempt through this path will either hang, crash, or silently fail against the Play Services billing service that no longer speaks v1.

This is not a blocker for the Go asset pipeline or the Godot rewrite, but it **is** a blocker for reaching later game states (fusion recipes, high-tier food unlocks, late-game cafe layouts) that the rewrite will eventually want reference fixtures for. The existing fixture extraction flow — rebuild APK with `android:debuggable="true"`, install to user 0, run-as pull via `adb` — already requires a custom rebuilt APK, so patching the IAP flow costs nothing extra at the build step.

The patch style mirrors the existing always-on patches in `src/lib/cpp/ZombieCafeExtension.cpp` (server URL rewrite, texture destructor NOPs, `SoundManager.setEnabled` no-op): unconditional, applied to the one-and-only rebuilt APK the user installs locally, and documented in-source so the intent is obvious to anyone reading the diff later.

## Success criteria

1. `apktool b` rebuilds `src/` into an installable APK with no smali syntax errors.
2. The rebuilt APK, signed with `debug.keystore` and installed via `adb install`, launches to gameplay without regression (no new boot-path crashes beyond the pre-existing `Scudo` GC heap bug).
3. When the player is low on toxin and tries to buy a chef, the 5-slot picker appears as usual. Tapping any slot credits the toxin amount within one frame, visible in the in-game toxin counter HUD.
4. The game does **not** enter a dim/frozen "waiting for purchase" overlay state after the slot tap — it returns immediately to normal gameplay.
5. `adb logcat -d | grep "SmurfsBilling bypass"` shows the bypass markers on each tap.
6. No traffic fires to any billing endpoint (verifiable by the absence of `com.capcom.billing.BillingService` in `adb shell dumpsys activity services` after a tap, and the absence of Play-Services-billing-related log lines).

## Approach: patch `SmurfsBilling.onCreate` to fake purchase success

The patch targets `src/smali/com/capcom/billing/SmurfsBilling.smali`, not `ZombieCafeAndroid.BuyToxin`. `BuyToxin` itself is **not touched** — it continues to build the Intent, set `mBuyingBerries=true`, and call `startActivity(SmurfsBilling)` exactly as the original game did. This is deliberate: the native game's shopping state machine expects an Activity-swap cycle (`onPause` → child Activity → `onResume`) when a slot is tapped, and short-circuiting `BuyToxin` to credit toxin directly leaves the native state machine stuck in a dim "awaiting purchase" overlay that only clears via the Android back button (see Findings below for how we discovered this).

Three methods in `SmurfsBilling.smali` are replaced:

### 1. `onCreate(Bundle)` — fake successful purchase on entry

The entire original `onCreate` body (setContentView, Handler/BillingService/cursor/adapter setup, BillingService.a() call, dialog fallbacks) is replaced with a minimal flow:

```
super.onCreate(savedInstanceState)
log "SmurfsBilling bypass" / "onCreate - faking purchase success"
intent = getIntent()
if (intent != null):
    extras = intent.getExtras()
    if (extras != null):
        productID = extras.getString("ItemName0")
        if (productID != null):
            log "SmurfsBilling bypass" / productID
            ZombieCafeAndroid.boughtToxin(productID)
finish()
return
```

`ItemName0` is already populated by the unchanged `ZombieCafeAndroid.BuyToxin` Google path, with short-form product IDs (`zc_50_toxin_3`, `zc_125_toxin_2`, etc.). `boughtToxin(String)` is the **exact same success callback** the original Google Play billing flow would have called after a real purchase cleared — it matches the product ID against its case switch, sets `purchaseAmount`, and calls `PurchaseAndroidToxin(amount)` on the main UI thread inside the Activity's onCreate context, which is the same thread context the original `j.run()` Runnable would have used. The native state machine therefore sees the credit applied exactly as a real purchase would have credited it.

After crediting, `finish()` pops the Activity, triggering `onPause` → `onStop` → `onDestroy` → `onResume` on the game Activity, which un-dims the overlay and returns control to gameplay.

### 2. `doFinish()` — null-safe

The original `doFinish()` dereferences `this.i` (an `e` field for a local purchase DB helper) and `this.e` (a `BillingService` field) and calls methods on both. In the bypass, neither field is ever initialized (the whole BillingService setup in the original onCreate is skipped), so dereferencing would NPE. `doFinish()` is replaced with a minimal "just call `finish()`" body. `onStop()`'s existing `invoke-virtual {p0}, ... ->doFinish()V` call therefore becomes safe without modifying `onStop` itself.

### 3. `onDestroy()` — null-safe

Same reasoning: the original `onDestroy()` calls methods on the `i` and `e` fields that would NPE. Replaced with just `super.onDestroy()` + return.

## What does NOT change

- **`ZombieCafeAndroid.BuyToxin(I)V`** — unchanged from the original APK. Same signature, same body, same Intent construction, same `startActivity` call.
- **`ZombieCafeAndroid.boughtToxin(String)`** — unchanged. This is the real success callback we're co-opting.
- **`ZombieCafeAndroid.boughtAmazonToxin()`** — unchanged. The Amazon path is separate and stays dead (the `amazonKindle` boolean is always false for this device anyway).
- **`PurchaseAndroidToxin(I)V` native declaration** — unchanged.
- **`com/capcom/billing/BillingService.smali`, `BillingReceiver.smali`, `Security.smali`, the `a.smali`–`q.smali` inner classes** — all unchanged. They become dead code at runtime since `SmurfsBilling.onCreate` never instantiates them.
- **`AndroidManifest.xml`** — unchanged. The `<service>`, `<receiver>`, and `<activity>` declarations for the billing classes stay in place. They do no harm when nothing dispatches an intent at them.
- **`src/lib/cpp/ZombieCafeExtension.cpp`** — unchanged. This is a pure smali change.
- **Lifecycle methods not called in the bypass path** — `onStart`, `onItemSelected`, `onNothingSelected`, `onRestoreInstanceState`, `onSaveInstanceState`, `onClick`, `onCreateDialog`, and the `a(II)`, `a(Lcom/capcom/billing/SmurfsBilling;...)` helpers all stay intact. They never run because `finish()` terminates the Activity before Android calls them, but we leave them present so the class still compiles cleanly and nothing references a missing method.

## Not gated

Unconditional in the rebuilt APK. No `BuildConfig.DEBUG` check, no `ApplicationInfo.FLAG_DEBUGGABLE` branch. Matches the style of every other patch in this fork and matches the reality that this APK is only ever built for local development use.

## Observability

Two `Log.d` calls in `SmurfsBilling.onCreate`:

1. `D/SmurfsBilling bypass: onCreate - faking purchase success` — fires on every entry to onCreate, confirming the patched Activity is loading
2. `D/SmurfsBilling bypass: <productID>` — fires when the Intent's `ItemName0` extra is successfully read, showing which slot was purchased

Capture on-device via:
```
adb logcat -d | grep "SmurfsBilling bypass"
```

## Verification plan

No automated tests. Verification is manual, matching how the existing `ZombieCafeExtension.cpp` patches are verified:

1. `go run ./tool/build_tool -i src/ -o build/` rebuilds the APK tree.
2. `cp src/lib/cpp/build/libZombieCafeExtension.so ./build/lib/armeabi/libZombieCafeExtension.so`
3. `apktool b ./build -o ./build/out/out.apk` — expect clean build, no smali syntax errors.
4. `jarsigner ... ./build/out/out.apk alias_name`
5. `adb install -r ./build/out/out.apk`
6. Force-stop and relaunch so the new APK is actually loaded: `adb shell am force-stop com.capcom.zombiecafeandroid && adb shell am start -n com.capcom.zombiecafeandroid/.ZombieCafeAndroid`
7. Play until the player has insufficient toxin, then attempt to buy a chef whose cost exceeds current toxin. The 5-slot picker opens.
8. Tap any slot. Expected: brief flash as `SmurfsBilling` opens and immediately finishes, game resumes cleanly, toxin counter increases by the slot amount, **no dim freeze**, no back-button needed.
9. Dump logcat: `adb logcat -d | grep "SmurfsBilling bypass"` → shows two lines per tap (the onCreate marker and the productID line).

If step 8 still shows a dim freeze, the hypothesis that the onPause/onResume cycle is what clears the native state is wrong, and the Findings section below should be consulted for the fallback `BuyToxin` direct-call approach that was confirmed to credit toxin (albeit with the back-button side effect).

## Rollback

`git revert` on the smali commit. No generated artifacts are committed — `build/` and `build/out/` are transient and gitignored. The design doc stays in the repo as a record of the decision.

---

## Findings from the 2026-04-12 session

### What we tried first and what we learned

The original design (see the "Approach" section above — but read this section first to understand why that section was rewritten) was to patch `ZombieCafeAndroid.BuyToxin(I)V` directly: replace the method body with a flat slot→amount packed-switch that calls `PurchaseAndroidToxin(amount)` inline and returns, skipping `startActivity(SmurfsBilling)` entirely.

On-device testing of that approach revealed:

1. **The bypass log fired as expected.** `D/BuyToxin bypass: slot=4 credited=2000` appeared in logcat at the exact moment the user tapped the 2000-toxin slot. The patched Java code ran cleanly.
2. **The toxin was actually credited.** `PurchaseAndroidToxin(int)` worked correctly when called directly from the render thread — the native game's currency counter updated with the 2000 toxin.
3. **BUT the game entered a dim "waiting for purchase" overlay state** immediately after the slot tap and stayed there indefinitely. The native C++ game's shopping state machine appears to transition into a `gPurchaseInProgress`-style state when a slot is tapped, and it relies on the Activity-swap cycle (onPause from the game, SmurfsBilling rendering, onResume back to the game) to clear that state. With the direct-call bypass skipping the Activity cycle, the native state never clears, the game freezes visually, and only the Android back button dismisses the overlay — at which point the (already-credited) toxin is visible in the HUD.

So the direct-call `BuyToxin` approach works *functionally* (toxin is credited) but fails *cosmetically* (dim freeze requires manual back-button dismissal). This is the reason the approach in the "Approach" section pivoted to patching `SmurfsBilling.onCreate` instead: by letting the Activity swap actually happen (but having the Activity immediately fake success and finish), the native state machine sees the full onPause/onResume cycle it expects, clears the dim state on its own, and the user never sees the freeze.

### Revert reference: original unpatched smali

If future on-device testing reveals the `SmurfsBilling.onCreate` approach is itself wrong (e.g. the dim state has a *different* root cause we haven't yet diagnosed, or the HUD store-path investigation below reveals a conflict), here is the original unpatched smali for each of the three touched methods, captured from the pristine APK decompilation. Restoring these exact bodies reverts `SmurfsBilling.smali` to its pre-bypass state.

**Original `onCreate(Landroid/os/Bundle;)V`** — ~280 lines including BillingService setup, cursor management, and dialog fallbacks. The method body is preserved in the apktool-disassembled APK (recoverable via `git show` on the pre-patch `src/smali/com/capcom/billing/SmurfsBilling.smali`) rather than duplicated here. Key characteristics:

- `.locals 10` — uses v0 through v9
- `invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V` as first instruction
- Reads `Intent.getExtras()`, iterates `NumberOfItems` looking up `ItemName0..ItemNameN` from the Bundle, populating `SmurfsBilling.a[]` and `SmurfsBilling.m[]` arrays
- Calls `setContentView(0x7f030000)`
- Instantiates `Handler`, `q`, `BillingService`, `e` and stores in fields `d`, `c`, `e`, `i`
- Calls `BillingService.a(Context)` to bind to the v1 billing IPC service
- Sets up a `SimpleCursorAdapter` for the ListView display
- Branches on `BillingService.a()` return to decide whether to call `showDialog(1)` or proceed with `BillingService.a(sku, payload)` for the actual purchase request

**Original `doFinish()V`:**
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

**Original `onDestroy()V`:**
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

A `git show HEAD~1:src/smali/com/capcom/billing/SmurfsBilling.smali` (after this patch is committed) will also yield the full original body of onCreate.

### Open question: HUD toxin icon does not open any store page

Separate from the low-toxin slot-picker flow that this spec fixes, the legacy APK has a "toxin" icon in the in-game HUD that, when tapped, plays a click sound effect but does not open any purchase UI. The user's expectation was that this icon should open a full "store" page with both cash and toxin purchase options.

This session investigated the HUD path thoroughly and reached a **definitive negative result**: the handler is pure native code with zero JNI calls out to Java, so Java/smali patching cannot fix it. The evidence:

**Phase 1 — Free logcat capture.** With the game running and no instrumentation, each tap of the HUD toxin icon produces exactly one native-emitted log line: `E GameStateCafe: BUTTON_ADDTOXIN`. Between taps and the next BUTTON_ADDTOXIN, the game's logcat stream is empty of any game-tagged output despite the game normally being extremely verbose (it logs `GameStateCafe::save()`, `ZombieCafe::serialize`, `CCServer::RetrieveMyGifts`, `GiftManager::PopGift`, URL requests, cursor ops, etc.). No `SmurfsBilling`, `BillingService`, `WebView`, `LaunchURL`, or `Dialog` markers fire.

Additionally, several `fromNative_*` methods already self-log in the original smali — `fromNative_NewRequest`, `fromNative_IsConnected`, `fromNative_URLRequest`, `fromNative_showDialog`, `fromNative_initDialog`, `fromNative_LoadFromURL` — and none of those markers appeared during the tap window either. `fromNative_NewRequest` only fired at a 60-second periodic interval for the unrelated gift poll.

**Phase 2 — Targeted probe instrumentation.** To prove the Java layer is uninvolved, the eight non-self-logging methods most likely to be the gate or UI opener were instrumented with `D HUDprobe: fromNative_XXX` log lines at the top: `fromNative_LoggedIn`, `fromNative_Connected`, `fromNative_IsAmazon`, `fromNative_IsKindle`, `fromNative_ShowWebView`, `fromNative_LaunchURL`, `fromNative_LaunchURL2`, `fromNative_PaypalButton`. The APK was rebuilt, installed, and the user tapped the HUD icon 9 times across two process lifetimes (the game crashed once mid-test from the pre-existing Scudo heap bug, aggravated by the probe instrumentation's log volume, and was relaunched). Probe hit counts over the full session:

| Method | Hit count | When |
|---|---|---|
| `fromNative_IsKindle` | 26,581 | Every frame in the render loop |
| `fromNative_LoggedIn` | 6 | Boot-time only, clustered within ~3s of each process start |
| `fromNative_Connected` | 6 | Boot-time only, same clustering |
| `fromNative_IsAmazon` | 2 | Boot-time only, one per process lifetime |
| `fromNative_ShowWebView` | **0** | — |
| `fromNative_LaunchURL` | **0** | — |
| `fromNative_LaunchURL2` | **0** | — |
| `fromNative_PaypalButton` | **0** | — |

Every single BUTTON_ADDTOXIN tap was bracketed by zero HUDprobe events. The `LoggedIn`/`Connected`/`IsAmazon` hits were boot-time status initialization, not tap responses. The four UI-opening methods — `ShowWebView`, `LaunchURL`, `LaunchURL2`, `PaypalButton` — fired **zero times for the entire session**.

**Conclusion.** The HUD toxin icon handler inside `libZombieCafeAndroid.so` is a native function that does **none of the following**: no JNI upcall to any Java method, no Intent dispatch, no WebView creation, no dialog init, no URL launch, no billing service binding. It logs the BUTTON_ADDTOXIN string via `__android_log_print` and then either returns silently or performs native-only bookkeeping that has no visible effect. The gate (if any) is in native code and not observable or patchable from smali.

**What this means for future work.** Unblocking the HUD store icon from the Java layer is **impossible**. The only viable paths to fix it are:

1. **Ghidra on `libZombieCafeAndroid.so`.** Find the BUTTON_ADDTOXIN handler (the function that emits `__android_log_print` with the `"GameStateCafe"` tag and `"BUTTON_ADDTOXIN"` message), identify the code path it takes after the log call, locate whatever condition gates the "show store" branch, and either NOP the gate or redirect the branch via `ZombieCafeExtension.cpp`'s runtime patching. Definitive but requires native-side reverse engineering effort. This is the only realistic path.
2. **Accept the limitation.** The low-toxin slot picker (patched by this spec) is sufficient for unlimited toxin acquisition via the "try to buy a chef you can't afford" trigger. Cash purchases are not available through the slot picker, but gameplay-driven cash accumulation is still available. For the fixture-extraction goal at the top of this spec, this is enough.

**Recommended action for callers of this spec:** option 2 unless a specific fixture-extraction need proves that the gameplay cash path is insufficient. If such a need arises, spin up a dedicated Ghidra session.

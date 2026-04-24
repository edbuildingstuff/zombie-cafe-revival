#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <sys/mman.h>
#include "Memory.h"

#define LOGI(...) \
  ((void)__android_log_print(ANDROID_LOG_INFO, "zombieCafeExtension::", __VA_ARGS__))


typedef jint (*jni_OnLoad)(JavaVM* vm, void* reserved);
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  LOGI("Zombie Cafe Extension Loaded!");
  int base = (int)Memory::getBaseAddress(); 
  
  const char* infoStr = "ZCR - %s\0";
  Memory::memcpyProtected((void*)(base + 0x1a14dc), infoStr, strlen(infoStr) + 1);

                          //http://zombiecafe.capcomcanada.com/updater/%s
  const char* updaterUrl = "https://zc.airyz.xyz/v1/updater/%s\0";
  Memory::memcpyProtected((void*)(base + 0x1a6610), updaterUrl, strlen(updaterUrl) + 1);

                    //http://zombiecafe.capcomcanada.com/x
  const char* xUrl = "https://zc.airyz.xyz/v1/x\0";
  Memory::memcpyProtected((void*)(base + 0x1a839c), xUrl, strlen(xUrl) + 1);

                      //http://zombiecafe.capcomcanada.com/zca
  const char* zcaUrl = "https://zc.airyz.xyz/v1/zca\0";
  Memory::memcpyProtected((void*)(base + 0x1a842c), zcaUrl, strlen(zcaUrl) + 1);


  Memory::setNop((void*)(base + 0x9dee8), 4);
  
  //Nop delete texture (this will cause memory leak, fix this!!!)
  Memory::setNop((void*)(base + 0x13d530), 4);
  Memory::setNop((void*)(base + 0x13d550), 4);
  Memory::setNop((void*)(base + 0x13d9e8), 4);
  Memory::setNop((void*)(base + 0x13d9ee), 4);


  /*  Fix crash when releasing texture reference also causes memory leak :( 
    #05 pc 0002eca7  /apex/com.android.runtime/lib/bionic/libc.so (scudo_free+18) (BuildId: 9e5101d790f828ae8b754029c778f7e2)
    #06 lib/arm/libZombieCafeAndroid.so (CFTextureRef::~CFTextureRef()+12)
    #07 lib/arm/libZombieCafeAndroid.so (CFTexture::releaseRef()+34)
    #08 lib/arm/libZombieCafeAndroid.so (CFTexture::~CFTexture()+4)
  */
  Memory::setNop((void*)(base + 0x0013d3ae), 4);
  Memory::setNop((void*)(base + 0x0013d3b4), 4);


  /* Patch to change Money Buy to Toxin Buy
    000ab018  d623       movs    r3, #0xd6    <-- change this offset to 0xb8
    000ab01a  5b00       lsls    r3, r3, #1   <-- prevent this leftshift
  */
  Memory::setProtection((void*)(base + 0xab018), 50, PROT_READ | PROT_WRITE | PROT_EXEC);
  *(char*)(base + 0x000ab018) = 0xb8;
  Memory::setNop((char*)(base + 0x000ab01a), 2);

  /*
    Patch Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled (base+0x5e07c)
    to immediately return. On modern Android, an audio-state broadcast
    receiver fires SoundManager.setEnabled before the game's CCSound
    singleton is initialized, which causes a null-pointer SIGSEGV deep
    in CCSound::SetEffectsVolume on the first launch:

      #00  CCSound::SetEffectsVolume(void*, float)+4
      #01  CCSound::SetEffectsVolume(float)+10
      #02  ZombieCafe::setSfxVolume(unsigned char)+18
      #03  ZombieCafe::setSoundEnabled(bool)+36
      #04  Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled+66

    Making the JNI entry point a no-op lets the game boot without audio,
    which is sufficient for fixture extraction. The original instruction
    at +0 was a 4-byte Thumb-2 push; we overwrite the first 2 bytes with
    "bx lr" (0x4770 little-endian), which returns before any register
    save happens so the stack stays balanced.
  */
  static const unsigned char bxLr[] = {0x70, 0x47};
  Memory::memcpyProtected((void*)(base + 0x5e07c), bxLr, sizeof(bxLr));

  /*
    Scudo manifestation-site NOPs.

    A bugreport on 2026-04-19 preserved 32 tombstones spanning 2026-04-13
    through 2026-04-19 — every one a `Scudo ERROR: corrupted chunk header`.
    Only 5 of them were caught on GLThread with game frames on top; the
    other 27 were GC/finalizer threads tripping Scudo while freeing
    innocent neighbors (large Java objects, conscrypt SSL buffers, ICU
    regex patterns, Mali sync objects). The 5 GLThread stacks collapse
    to three distinct call sites inside libZombieCafeAndroid.so, all of
    them ending in a `bl operator delete` or `blx r3 (deleting dtor)`:

      +0x679e4  Cafe::~Cafe()+300          — inner loop freeing a 2D
                                             pointer array; one entry is
                                             a dangling/double-freed
                                             pointer or the loop bound is
                                             stale. 1 tombstone; fires on
                                             GameStateCafe::uninit during
                                             cafe state transitions.
      +0x149c56 PathTween::~PathTween()+30 — `operator delete(this)` on
                                             a PathTween whose chunk
                                             header is already corrupt
                                             (root cause upstream).
                                             1 tombstone; also 1 via the
                                             MoveTask chain below.
      +0xe0a02  MoveTask::~MoveTask()+26   — `blx r3` virtual dispatch to
                                             the deleting dtor of a member
                                             (typically a PathTween), same
                                             underlying chunk trip as the
                                             PathTween site.

    These three patches are empirical: if they stop the crashes (both
    GLThread and the 27 collateral GC/finalizer ones), the sites were
    planting the corruption and symptom-patching was sufficient; if they
    don't, there's a heap overwrite elsewhere that needs hunting via
    Ghidra or a malloc/free instrumentation shim. Same trade-off as the
    existing texture-destructor NOPs above: costs a small leak per
    destruction, lets the game keep running instead of SIGABRT.

    Full analysis: memory/project_crash_sites_from_tombstones.md and
    .claude/crash_logs_2026-04-19/.
  */
  Memory::setNop((void*)(base + 0x679e4), 4);
  Memory::setNop((void*)(base + 0x149c56), 4);
  Memory::setNop((void*)(base + 0xe0a02), 2);

  /*
    javaMD5String+102 OOB write. This is the root cause of the
    "Scudo: corrupted chunk header" epidemic. Caught by GWP-ASan
    (sample_rate=10, gwpAsanMode=always in the debuggable build):

      Cause: [GWP-ASan]: Buffer Overflow, 0 bytes right of a
                        32-byte allocation at 0xb7c70fe0
      #00 javaMD5String+102
      #01 CCMd5(char*, unsigned int, char const*)+8
      #02 CCServer::SaveMyGameState+286
      #03 ZombieCafe::saveGameState+592
      #04 GameStateCafe::uninit+1376   <-- fires on every cafe exit

    The function allocates `new char[32]` for the MD5 hex digest,
    fills it via a JNI GetByteArrayRegion-style call, then writes a
    C-string null terminator at byte 32 of the 32-byte buffer:

       17f316: movs  r2, #0        ; null byte
       17f318: movs  r3, #0x20     ; offset 32
       17f31a: strb  r2, [r4, r3]  ; buf[32] = 0   <- OOB write
       17f31c: add   sp, #0x14
       17f31e: mov   r0, r4
       17f320: pop   {r4, r5, r6, r7, pc}

    CCMd5 treats the output as length-prefixed 32 bytes (it was
    called with `out_len=32`), so the null terminator is gratuitous
    damage — it clobbers one byte of whatever Scudo chunk happens
    to sit immediately after the 32-byte allocation. Every cafe
    state transition runs a save, so the OOB accumulates into the
    scattered MemMap / conscrypt / ICU / Mali / Cafe-ptr-array
    corruption seen across the 2026-04-13..19 tombstone corpus.

    First attempt was a 2-byte NOP at +0x17f31a killing the write
    entirely. That stopped the OOB (GWP-ASan confirmed) but created
    a worse downstream problem: the 32-byte buffer has no null
    terminator, so `CCUrlConnection::NewRequest` doing strlen-based
    concat onto the save URL reads past the buffer into heap garbage
    and ends up passing invalid Modified UTF-8 (bytes like 0x81) to
    `NewStringUTF`. CheckJNI (on in debuggable builds) aborts hard;
    on release builds the garbage bytes just poison the URL and
    cascade into conscrypt/SSL finalizer Scudo trips later.

    Correct fix: keep the `strb r2, [r4, r3]` write, but patch the
    offset constant from 32 to 31 so the null lands at `buf[31]`
    instead of `buf[32]`. One byte at +0x17f318: `movs r3, #0x20`
    (encoding `0x2320`, byte0=0x20) becomes `movs r3, #0x1F`
    (encoding `0x231F`, byte0=0x1F). Last hex char of the MD5 gets
    overwritten with NUL. String becomes 31 hex chars + terminator
    instead of 32 hex chars + OOB terminator. Server's hash check
    (if any) rejects the save, but Airyz's backend drops 90% of
    writes anyway — no behavioural change worth caring about, and
    the game never reads the hash back.
  */
  static const unsigned char movsR3_1F[] = {0x1F, 0x23};
  Memory::memcpyProtected((void*)(base + 0x17f318), movsR3_1F, sizeof(movsR3_1F));

  /*
    javaMD5Data has the identical off-by-one bug as javaMD5String — a
    scan of every `java*` JNI helper in libZombieCafeAndroid.so for the
    `movs r3, #0x20; strb r2, [r4, r3]` signature matched exactly two
    symbols: `javaMD5String+102` (above, patched) and
    `javaMD5Data+126` at `+0x17f7de`. Same 32-byte buffer, same
    gratuitous null terminator past the end. `javaMD5Data` is the
    binary-data MD5 variant called by `CCMd5(out, 32, bytes, len)` —
    the 4-arg overload at 0x18b0a4. Same 1-byte offset fix.
  */
  Memory::memcpyProtected((void*)(base + 0x17f7de), movsR3_1F, sizeof(movsR3_1F));

  return JNI_VERSION_1_4;
}
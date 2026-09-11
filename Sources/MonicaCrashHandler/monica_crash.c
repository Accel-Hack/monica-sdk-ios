#include "monica_crash.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <pthread/introspection.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#define MONICA_STRIP_RETURN_ADDRESS(value) \
  ((uintptr_t)ptrauth_strip((void *)(value), ptrauth_key_return_address))
#else
#define MONICA_STRIP_RETURN_ADDRESS(value) ((uintptr_t)(value))
#endif

/* The signals iOS delivers for the crashes an application can cause: abort()
 * (NSException, Swift runtime failures on some paths), memory faults, Swift
 * traps (brk -> SIGTRAP on arm64, ud2 -> SIGILL on x86_64), and arithmetic. */
static const int monica_signals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP};
#define MONICA_SIGNAL_COUNT (sizeof(monica_signals) / sizeof(monica_signals[0]))

static struct sigaction previous_actions[MONICA_SIGNAL_COUNT];
static struct sigaction our_action;
static bool installed = false;
static char report_path[MONICA_CRASH_MAX_PATH];
/* The report is written here and renamed onto report_path, so the final path
 * only ever appears complete. */
static char report_temp_path[MONICA_CRASH_MAX_PATH + 8];
static atomic_int reporting = 0;
/* Set once a report has been renamed into place. A second thread that faults
 * while the first is still writing waits for this instead of killing the
 * process out from under the writer. */
static atomic_int report_written = 0;

static monica_crash_image images[MONICA_CRASH_MAX_IMAGES];
static atomic_uint image_count = 0;
static pthread_mutex_t image_lock = PTHREAD_MUTEX_INITIALIZER;
static bool image_tracking = false;

/* Signal-handler stacks. A stack overflow is one of the crashes worth catching,
 * and the handler cannot run on a stack that has just run out.
 *
 * `sigaltstack` is per-thread state, so one static buffer installed on whoever
 * called `monica_crash_install` left every other thread without one: a
 * background thread that overflowed its 512 KB stack ran the handler on the
 * exhausted stack, hit the guard page, and the kernel killed the process with
 * the signal blocked and nothing written. One buffer also cannot serve two
 * threads that fault at once. Each thread therefore gets its own, allocated
 * when the thread starts. */
#define MONICA_ALTSTACK_SIZE ((size_t)MINSIGSTKSZ + 16 * 1024)
static pthread_key_t altstack_key;
static pthread_introspection_hook_t previous_introspection_hook = NULL;
/* The hook and the key are process-wide and installed exactly once, whatever
 * install/uninstall does afterwards. Installing twice would chain the hook onto
 * itself and recurse until the thread's stack is gone. */
static bool introspection_installed = false;
/* Whether the hook still allocates stacks. Cleared by uninstall. */
static bool altstack_tracking = false;

static void release_altstack(void *buffer) {
  stack_t disable;
  memset(&disable, 0, sizeof(disable));
  disable.ss_flags = SS_DISABLE;
  sigaltstack(&disable, NULL);
  free(buffer);
}

static void install_altstack_for_current_thread(void) {
  stack_t existing;
  /* Do not take an alternate stack away from a library that installed its own;
   * SA_ONSTACK will use theirs, which is as good for our purposes. */
  if (sigaltstack(NULL, &existing) == 0 && existing.ss_sp != NULL && (existing.ss_flags & SS_DISABLE) == 0) return;
  if (pthread_getspecific(altstack_key) != NULL) return;
  void *buffer = malloc(MONICA_ALTSTACK_SIZE);
  if (buffer == NULL) return;
  stack_t stack;
  stack.ss_sp = buffer;
  stack.ss_size = MONICA_ALTSTACK_SIZE;
  stack.ss_flags = 0;
  if (sigaltstack(&stack, NULL) != 0) {
    free(buffer);
    return;
  }
  /* The key's destructor disables the stack and frees it at thread exit. */
  if (pthread_setspecific(altstack_key, buffer) != 0) return;
}

/* THREAD_START and THREAD_TERMINATE are delivered on the thread itself, which
 * is the only context in which `sigaltstack` can speak for it. Whatever hook
 * was installed before us keeps running: replacing it silently would break
 * another library's thread bookkeeping. */
static void introspection_hook(unsigned int event, pthread_t thread, void *address, size_t size) {
  if (event == PTHREAD_INTROSPECTION_THREAD_START && altstack_tracking) {
    install_altstack_for_current_thread();
  }
  if (previous_introspection_hook != NULL) previous_introspection_hook(event, thread, address, size);
}

/* --- image table (normal context) ---------------------------------------- */

bool monica_crash_uuid_of(const void *mach_header, uint8_t out[16]) {
  const struct mach_header *header = mach_header;
  const uint8_t *cursor;
  uint32_t count;
  if (header == NULL) return false;
  if (header->magic == MH_MAGIC_64) {
    cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
  } else if (header->magic == MH_MAGIC) {
    cursor = (const uint8_t *)header + sizeof(struct mach_header);
  } else {
    return false;
  }
  count = header->ncmds;
  const uint8_t *end = cursor + header->sizeofcmds;
  for (uint32_t index = 0; index < count; index++) {
    const struct load_command *command = (const struct load_command *)cursor;
    if (cursor + sizeof(struct load_command) > end) return false;
    if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > end) return false;
    if (command->cmd == LC_UUID) {
      memcpy(out, ((const struct uuid_command *)command)->uuid, 16);
      return true;
    }
    cursor += command->cmdsize;
  }
  return false;
}

static void image_added(const struct mach_header *header, intptr_t slide) {
  (void)slide;
  Dl_info info;
  monica_crash_image entry;
  memset(&entry, 0, sizeof(entry));
  entry.load_address = (uint64_t)(uintptr_t)header;
  if (!monica_crash_uuid_of(header, entry.uuid)) memset(entry.uuid, 0, sizeof(entry.uuid));
  if (dladdr(header, &info) != 0 && info.dli_fname != NULL) {
    strncpy(entry.path, info.dli_fname, MONICA_CRASH_MAX_PATH - 1);
  }

  pthread_mutex_lock(&image_lock);
  unsigned int count = atomic_load(&image_count);
  /* Rows freed by image_removed keep their index; reuse one before growing so a
   * process that loads and unloads bundles never exhausts the table. */
  for (unsigned int index = 0; index < count; index++) {
    if (__atomic_load_n(&images[index].load_address, __ATOMIC_RELAXED) != 0) continue;
    /* The handler reads this table without the lock and keys every frame off
     * `load_address`, so it must never see a new address next to the previous
     * image's uuid and path. Fill the descriptive fields first and publish the
     * address last. (The append path below does the same by publishing
     * `image_count` after the row.) */
    memcpy(images[index].uuid, entry.uuid, sizeof(entry.uuid));
    memcpy(images[index].path, entry.path, sizeof(entry.path));
    __atomic_store_n(&images[index].load_address, entry.load_address, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&image_lock);
    return;
  }
  if (count < MONICA_CRASH_MAX_IMAGES) {
    images[count] = entry;
    /* Publish the count only after the entry is complete so a handler that
     * runs concurrently never reads a half-written row. */
    atomic_store(&image_count, count + 1);
  }
  pthread_mutex_unlock(&image_lock);
}

static void image_removed(const struct mach_header *header, intptr_t slide) {
  (void)slide;
  pthread_mutex_lock(&image_lock);
  unsigned int count = atomic_load(&image_count);
  for (unsigned int index = 0; index < count; index++) {
    if (__atomic_load_n(&images[index].load_address, __ATOMIC_RELAXED) != (uint64_t)(uintptr_t)header) continue;
    /* Keep the row so indices stay stable for the handler; a zero address
     * marks it unused. */
    __atomic_store_n(&images[index].load_address, (uint64_t)0, __ATOMIC_RELEASE);
    break;
  }
  pthread_mutex_unlock(&image_lock);
}

uint32_t monica_crash_image_count(void) {
  return atomic_load(&image_count);
}

bool monica_crash_image_at(uint32_t index, monica_crash_image *out) {
  if (out == NULL || index >= atomic_load(&image_count)) return false;
  pthread_mutex_lock(&image_lock);
  *out = images[index];
  pthread_mutex_unlock(&image_lock);
  return out->load_address != 0;
}

/* --- report writer (async-signal-safe) ------------------------------------ */

static bool write_all(int fd, const void *bytes, size_t length) {
  const char *cursor = bytes;
  while (length > 0) {
    ssize_t written = write(fd, cursor, length);
    if (written <= 0) return false;
    cursor += written;
    length -= (size_t)written;
  }
  return true;
}

static bool write_u32(int fd, uint32_t value) { return write_all(fd, &value, sizeof(value)); }
static bool write_i32(int fd, int32_t value) { return write_all(fd, &value, sizeof(value)); }
static bool write_u64(int fd, uint64_t value) { return write_all(fd, &value, sizeof(value)); }
static bool write_i64(int fd, int64_t value) { return write_all(fd, &value, sizeof(value)); }

#define MONICA_CRASH_MAX_TEXT 4096

static bool write_text(int fd, const char *text) {
  uint32_t length = text == NULL ? 0 : (uint32_t)strnlen(text, MONICA_CRASH_MAX_TEXT);
  if (!write_u32(fd, length)) return false;
  return length == 0 || write_all(fd, text, length);
}

/* Writes to a sibling path and renames, so a report that could not be finished
 * never appears at `report_path`.
 *
 * Writing in place with O_TRUNC left a truncated file behind whenever the write
 * failed part-way (ENOSPC) or a second thread faulted and killed the process
 * while this one was still writing. The next launch then read a prefix,
 * deleted it, failed to parse it, and the crash was gone without a trace.
 * `open`, `write`, `rename` and `unlink` are all async-signal-safe. */
static void write_report(uint32_t kind, int32_t signal_number, int32_t code, uint64_t fault_address,
                         const uint64_t *frames, uint32_t frame_count,
                         const char *name, const char *reason) {
  struct timeval now;
  gettimeofday(&now, NULL);
  int fd = open(report_temp_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) return;

  bool ok = write_u32(fd, MONICA_CRASH_REPORT_MAGIC) && write_u32(fd, MONICA_CRASH_REPORT_VERSION) &&
            write_u32(fd, kind) && write_i32(fd, signal_number) && write_i32(fd, code) &&
            write_u64(fd, fault_address) && write_i64(fd, (int64_t)now.tv_sec) &&
            write_u32(fd, frame_count);
  for (uint32_t index = 0; ok && index < frame_count; index++) ok = write_u64(fd, frames[index]);

  uint32_t count = atomic_load(&image_count);
  ok = ok && write_u32(fd, count);
  for (uint32_t index = 0; ok && index < count; index++) {
    const monica_crash_image *image = &images[index];
    /* Read the address once, with the acquire that pairs with image_added's
     * release: the uuid and path below must be the ones it was published with. */
    uint64_t load_address = __atomic_load_n(&image->load_address, __ATOMIC_ACQUIRE);
    uint32_t path_length = (uint32_t)strnlen(image->path, MONICA_CRASH_MAX_PATH);
    ok = write_u64(fd, load_address) && write_all(fd, image->uuid, 16) &&
         write_u32(fd, path_length) && (path_length == 0 || write_all(fd, image->path, path_length));
  }
  ok = ok && write_text(fd, name) && write_text(fd, reason);
  close(fd);
  if (ok && rename(report_temp_path, report_path) == 0) {
    atomic_store(&report_written, 1);
  } else {
    unlink(report_temp_path);
  }
}

/* Removes a report this handler just wrote, for the case where the signal
 * turned out to be survivable. */
static void discard_report(void) {
  unlink(report_path);
  atomic_store(&report_written, 0);
}

/* A second thread faulted while the first is still inside write_report. Give
 * the writer a bounded moment to finish rather than tearing the process down
 * mid-report. `nanosleep` is async-signal-safe. */
static void wait_for_report(void) {
  for (int attempt = 0; attempt < 500; attempt++) {
    if (atomic_load(&report_written) != 0) return;
    struct timespec pause;
    pause.tv_sec = 0;
    pause.tv_nsec = 1000000; /* 1 ms, so at most half a second in total. */
    nanosleep(&pause, NULL);
  }
}

/* --- stack walk (async-signal-safe) -------------------------------------- */

static uint32_t walk_stack(void *context, uint64_t *frames, uint32_t max) {
  uintptr_t pc = 0, lr = 0, fp = 0;
  ucontext_t *ucontext = context;
  if (ucontext == NULL || ucontext->uc_mcontext == NULL) return 0;
#if defined(__arm64__)
  pc = (uintptr_t)arm_thread_state64_get_pc(ucontext->uc_mcontext->__ss);
  lr = (uintptr_t)arm_thread_state64_get_lr(ucontext->uc_mcontext->__ss);
  fp = (uintptr_t)arm_thread_state64_get_fp(ucontext->uc_mcontext->__ss);
#elif defined(__x86_64__)
  pc = (uintptr_t)ucontext->uc_mcontext->__ss.__rip;
  fp = (uintptr_t)ucontext->uc_mcontext->__ss.__rbp;
#else
  return 0;
#endif

  /* Only dereference frame pointers that lie inside this thread's own stack.
   * A corrupted chain must not fault inside the handler: that second fault
   * would arrive with the signal blocked and the kernel would kill the process
   * before anything is written. */
  pthread_t self = pthread_self();
  uintptr_t stack_top = (uintptr_t)pthread_get_stackaddr_np(self);
  uintptr_t stack_bottom = stack_top - pthread_get_stacksize_np(self);

  if (stack_top < stack_bottom || stack_top - stack_bottom < 2 * sizeof(uintptr_t)) return 0;
  uintptr_t last_frame = stack_top - 2 * sizeof(uintptr_t);

  uint32_t count = 0;
  if (pc != 0 && count < max) frames[count++] = pc;
  if (lr != 0 && lr != pc && count < max) frames[count++] = MONICA_STRIP_RETURN_ADDRESS(lr);

  while (count < max) {
    /* Compare against a precomputed limit: `fp + 16` could wrap for a wild fp. */
    if (fp < stack_bottom || fp > last_frame || (fp & (sizeof(uintptr_t) - 1)) != 0) break;
    uintptr_t next_fp = ((const uintptr_t *)fp)[0];
    uintptr_t return_address = MONICA_STRIP_RETURN_ADDRESS(((const uintptr_t *)fp)[1]);
    if (return_address == 0) break;
    /* The live lr is usually the same return address the first frame record
     * holds; do not report it twice. */
    if (count == 0 || frames[count - 1] != return_address) frames[count++] = return_address;
    if (next_fp <= fp) break;
    fp = next_fp;
  }
  return count;
}

/* --- signal handler ------------------------------------------------------ */

static int index_of_signal(int signal_number) {
  for (size_t index = 0; index < MONICA_SIGNAL_COUNT; index++) {
    if (monica_signals[index] == signal_number) return (int)index;
  }
  return -1;
}

/* Puts this handler back in charge after a signal the process survived.
 * Without this, the first delivery of any of the six signals was the last one
 * that could ever be reported: the handler always restored the previous
 * disposition and never re-armed, and `reporting` stayed set. */
static void rearm(int signal_number, bool allow_new_report) {
  /* Only the invocation that actually wrote the report may clear the flag.
   * A report written by another thread -- or by the NSException handler just
   * before its abort() -- describes the real crash and must not be replaced. */
  if (allow_new_report) atomic_store(&reporting, 0);
  if (!installed) return;
  sigaction(signal_number, &our_action, NULL);
}

static void handle_signal(int signal_number, siginfo_t *info, void *context) {
  bool wrote = false;
  int expected = 0;
  if (atomic_compare_exchange_strong(&reporting, &expected, 1)) {
    uint64_t frames[MONICA_CRASH_MAX_FRAMES];
    uint32_t frame_count = walk_stack(context, frames, MONICA_CRASH_MAX_FRAMES);
    write_report(MONICA_CRASH_KIND_SIGNAL, signal_number, info == NULL ? 0 : info->si_code,
                 info == NULL ? 0 : (uint64_t)(uintptr_t)info->si_addr, frames, frame_count, NULL, NULL);
    wrote = true;
  } else {
    /* Another thread is reporting. Let it finish before this one hands the
     * crash back and the process dies. */
    wait_for_report();
  }

  /* Hand the crash back. Restoring the previous disposition and returning
   * re-executes the faulting instruction, so the process dies of the original
   * signal and the OS crash log stays intact. A handler that was installed
   * before MONICA is called the way the kernel would have called it. */
  int index = index_of_signal(signal_number);
  struct sigaction previous;
  if (index >= 0) {
    previous = previous_actions[index];
  } else {
    memset(&previous, 0, sizeof(previous));
    previous.sa_handler = SIG_DFL;
  }
  sigaction(signal_number, &previous, NULL);
  /* sa_handler and sa_sigaction share a union, so test the two reserved values
   * before trusting SA_SIGINFO: SIG_IGN is (void *)1 and must not be called. */
  if (previous.sa_handler == SIG_IGN) {
    /* The disposition in place before MONICA was "ignore", so the signal is
     * survivable by definition and the report we just wrote describes a crash
     * that is not happening. Throw it away and take the handler back, or the
     * application's next real crash would go unreported and this launch would
     * send a fatal event for a process that is still running. */
    if (wrote) discard_report();
    rearm(signal_number, wrote);
    return;
  }
  if (previous.sa_handler == SIG_DFL) {
    return;
  }
  if ((previous.sa_flags & SA_SIGINFO) != 0) {
    previous.sa_sigaction(signal_number, info, context);
  } else {
    previous.sa_handler(signal_number);
  }
  /* Control came back, so the chained handler returned instead of ending the
   * process. Take the handler back so a later crash is still captured. The
   * report stays on disk: from here there is no way to tell whether the
   * re-executed instruction will fault again fatally (keep it) or whether the
   * chained handler fixed things up (a false fatal on the next launch), and
   * losing a real crash is the worse of the two. */
  rearm(signal_number, wrote);
}

/* --- public API ---------------------------------------------------------- */

bool monica_crash_install(const char *path) {
  if (path == NULL || strlen(path) >= MONICA_CRASH_MAX_PATH) return false;
  if (installed) monica_crash_uninstall();
  strncpy(report_path, path, MONICA_CRASH_MAX_PATH - 1);
  report_path[MONICA_CRASH_MAX_PATH - 1] = '\0';
  snprintf(report_temp_path, sizeof(report_temp_path), "%s.part", report_path);

  if (!image_tracking) {
    /* dyld calls this back for every image already loaded, then for each new one. */
    _dyld_register_func_for_add_image(image_added);
    _dyld_register_func_for_remove_image(image_removed);
    image_tracking = true;
  }

  /* One alternate stack per thread: this one now, every thread started from
   * here on through the introspection hook. Threads that already existed when
   * install ran keep whatever they had (usually none), which is the one gap
   * left -- install early, before the app spawns its own threads. */
  if (!introspection_installed) {
    if (pthread_key_create(&altstack_key, release_altstack) != 0) return false;
    introspection_installed = true;
    previous_introspection_hook = pthread_introspection_hook_install(introspection_hook);
    if (previous_introspection_hook == introspection_hook) previous_introspection_hook = NULL;
  }
  altstack_tracking = true;
  install_altstack_for_current_thread();

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = handle_signal;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  our_action = action;

  for (size_t index = 0; index < MONICA_SIGNAL_COUNT; index++) {
    if (sigaction(monica_signals[index], &action, &previous_actions[index]) != 0) {
      /* Half-installed handlers would be unremovable and report a subset of
       * crashes with nobody the wiser. Undo and let the caller know. */
      for (size_t undo = 0; undo < index; undo++) {
        sigaction(monica_signals[undo], &previous_actions[undo], NULL);
      }
      return false;
    }
  }
  installed = true;
  return true;
}

void monica_crash_uninstall(void) {
  if (!installed) return;
  /* The introspection hook stays installed: another library may have chained
   * onto it since, and swapping it back would silently unhook them. Clearing
   * the flag is enough to stop allocating alternate stacks. */
  altstack_tracking = false;
  for (size_t index = 0; index < MONICA_SIGNAL_COUNT; index++) {
    struct sigaction current;
    /* Only step aside if we are still the handler; otherwise something that
     * installed itself on top of us would lose its own delegate. */
    if (sigaction(monica_signals[index], NULL, &current) == 0 && current.sa_sigaction == handle_signal) {
      sigaction(monica_signals[index], &previous_actions[index], NULL);
    }
  }
  installed = false;
}

void monica_crash_record_exception(const char *name, const char *reason,
                                   const uint64_t *addresses, uint32_t count) {
  int expected = 0;
  if (!installed) return;
  if (!atomic_compare_exchange_strong(&reporting, &expected, 1)) return;
  if (count > MONICA_CRASH_MAX_FRAMES) count = MONICA_CRASH_MAX_FRAMES;
  write_report(MONICA_CRASH_KIND_EXCEPTION, 0, 0, 0, addresses, count, name, reason);
}

bool monica_crash_has_reported(void) {
  return atomic_load(&reporting) != 0;
}

void monica_crash_reset_for_testing(void) {
  atomic_store(&reporting, 0);
}

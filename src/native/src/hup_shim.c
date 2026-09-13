/* SIGHUP, delivered safely to a Vyto event loop.
 *
 * A signal handler may interrupt malloc while it holds its lock, so calling
 * back into Vyto from one can deadlock or corrupt the allocator. The handler
 * here therefore does the only two things async-signal-safe code may do: it
 * writes a flag and returns. The loop reads the flag between polls, where
 * allocating is safe again.
 *
 * The flag is `volatile sig_atomic_t` because that is the one type the C
 * standard guarantees can be written by a handler and read by the main flow
 * without tearing.
 *
 * Platform arm: Windows has no sigaction and no SIGHUP. The stubs there report
 * "no signal ever arrived", which is accurate — a Windows build reloads by
 * restarting. This file compiles on every target because the package's
 * native/src is globbed flat with no per-file platform filter.
 */

#include <signal.h>

static volatile sig_atomic_t g_hup = 0;

#if defined(_WIN32)

void vp_install_hup(void) { }
int  vp_hup_pending(void) { return 0; }
void vp_clear_hup(void)   { g_hup = 0; }
/* No SIGPIPE on Windows: a dead peer surfaces as a send() error already. */
void vp_ignore_sigpipe(void) { }

#else

static void on_hup(int signo) { (void)signo; g_hup = 1; }

void vp_install_hup(void) {
    struct sigaction sa;
    sa.sa_handler = on_hup;
    sigemptyset(&sa.sa_mask);
    /* SA_RESTART so a signal does not turn every in-flight read into EINTR;
     * the loop learns about the reload from the flag, not from an error. */
    sa.sa_flags = SA_RESTART;
    sigaction(SIGHUP, &sa, 0);
}

int  vp_hup_pending(void) { return (int)g_hup; }
void vp_clear_hup(void)   { g_hup = 0; }

/* Writing to a socket whose peer has gone raises SIGPIPE, which by default
 * kills the process. A proxy has peers vanish constantly and must see the
 * EPIPE return value instead. SIG_IGN is a C macro, so this belongs here
 * rather than in an extern "C" call from Vyto. */
void vp_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); }

#endif

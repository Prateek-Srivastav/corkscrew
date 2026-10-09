/* Benchmark: what Win32 calls games make often cost under Wine. A Wine system call (e.g.
 * QueryPerformanceCounter) should take tens of nanoseconds; with msync (WINEMSYNC=1) an event
 * round trip between two threads takes a few microseconds, about 20 without it.
 * Prints one line per call, then timer accuracy and what the CPU reports through Rosetta. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <intrin.h>

static double freq;
static double now_s(void) { LARGE_INTEGER c; QueryPerformanceCounter(&c); return c.QuadPart / freq; }

#define BENCH(name, n, body) do { \
    double t0 = now_s(); \
    for (long i_ = 0; i_ < (n); i_++) { body; } \
    double t1 = now_s(); \
    printf("%-34s %8.1f ns/call\n", name, (t1 - t0) * 1e9 / (n)); \
} while (0)

static HANDLE ev_a, ev_b;
static volatile LONG stop;
static DWORD WINAPI pong(void *arg)
{
    while (!stop) { WaitForSingleObject(ev_a, INFINITE); SetEvent(ev_b); }
    return 0;
}

static SRWLOCK srw = SRWLOCK_INIT;
static CONDITION_VARIABLE cv = CONDITION_VARIABLE_INIT;
static volatile LONG turn;
static DWORD WINAPI cv_pong(void *arg)
{
    AcquireSRWLockExclusive(&srw);
    while (!stop) {
        while (turn != 1 && !stop) SleepConditionVariableSRW(&cv, &srw, INFINITE, 0);
        turn = 0;
        WakeAllConditionVariable(&cv);
    }
    ReleaseSRWLockExclusive(&srw);
    return 0;
}

int main(int argc, char **argv)
{
    LARGE_INTEGER f; QueryPerformanceFrequency(&f); freq = (double)f.QuadPart;
    LARGE_INTEGER c; FILETIME ft; CRITICAL_SECTION cs; InitializeCriticalSection(&cs);
    volatile ULONGLONG sink = 0;
    printf("qpc_frequency=%lld\n", f.QuadPart);

    BENCH("QueryPerformanceCounter", 2000000, QueryPerformanceCounter(&c); sink += c.QuadPart);
    BENCH("GetTickCount64", 2000000, sink += GetTickCount64());
    BENCH("GetSystemTimeAsFileTime", 2000000, GetSystemTimeAsFileTime(&ft); sink += ft.dwLowDateTime);
    BENCH("GetSystemTimePreciseAsFileTime", 2000000, GetSystemTimePreciseAsFileTime(&ft); sink += ft.dwLowDateTime);
    BENCH("__rdtsc", 2000000, sink += __rdtsc());
    BENCH("Enter/LeaveCriticalSection", 5000000, EnterCriticalSection(&cs); LeaveCriticalSection(&cs));
    BENCH("TlsGetValue", 5000000, sink += (ULONG_PTR)TlsGetValue(0));
    HANDLE signaled = CreateEventW(NULL, TRUE, TRUE, NULL);
    BENCH("WaitForSingleObject(signaled, 0)", 500000, sink += WaitForSingleObject(signaled, 0));
    BENCH("SetEvent", 500000, SetEvent(signaled));
    BENCH("ResetEvent+SetEvent", 500000, ResetEvent(signaled); SetEvent(signaled));
    BENCH("SwitchToThread", 200000, SwitchToThread());
    BENCH("Sleep(0)", 200000, Sleep(0));
    BENCH("GetCurrentThreadId", 5000000, sink += GetCurrentThreadId());
    BENCH("GetLastError", 5000000, sink += GetLastError());
    BENCH("VirtualAlloc+Free 64K", 100000, VirtualFree(VirtualAlloc(NULL, 65536, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE), 0, MEM_RELEASE));
    BENCH("HeapAlloc+Free 256B", 2000000, HeapFree(GetProcessHeap(), 0, HeapAlloc(GetProcessHeap(), 0, 256)));
    MSG msg;
    BENCH("PeekMessage (empty queue)", 200000, PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE));

    ev_a = CreateEventW(NULL, FALSE, FALSE, NULL);
    ev_b = CreateEventW(NULL, FALSE, FALSE, NULL);
    HANDLE t = CreateThread(NULL, 0, pong, NULL, 0, NULL);
    BENCH("event ping-pong round trip", 100000, SetEvent(ev_a); WaitForSingleObject(ev_b, INFINITE));
    stop = 1; SetEvent(ev_a); WaitForSingleObject(t, INFINITE); stop = 0;

    t = CreateThread(NULL, 0, cv_pong, NULL, 0, NULL);
    BENCH("SRW+CondVar ping-pong round trip", 100000,
          AcquireSRWLockExclusive(&srw); turn = 1; WakeAllConditionVariable(&cv);
          while (turn != 0) SleepConditionVariableSRW(&cv, &srw, INFINITE, 0);
          ReleaseSRWLockExclusive(&srw));
    AcquireSRWLockExclusive(&srw); stop = 1; WakeAllConditionVariable(&cv); ReleaseSRWLockExclusive(&srw);
    WaitForSingleObject(t, INFINITE);

    timeBeginPeriod(1);
    double t0 = now_s();
    for (int i = 0; i < 200; i++) Sleep(1);
    printf("%-34s %8.3f ms\n", "Sleep(1) actual", (now_s() - t0) * 1000 / 200);
    t0 = now_s();
    HANDLE timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    for (int i = 0; i < 200; i++) { LARGE_INTEGER due = { .QuadPart = -5000 }; SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE); WaitForSingleObject(timer, INFINITE); }
    printf("%-34s %8.3f ms\n", "500us waitable timer actual", (now_s() - t0) * 1000 / 200);

    /* rdtsc rate vs QPC */
    ULONGLONG r0 = __rdtsc(); double q0 = now_s(); Sleep(200); ULONGLONG r1 = __rdtsc(); double q1 = now_s();
    printf("rdtsc_rate_mhz=%.3f\n", (r1 - r0) / (q1 - q0) / 1e6);
    int regs[4]; __cpuid(regs, 1);
    printf("cpuid1 ecx=%08x edx=%08x (avx=%d xsave=%d osxsave=%d)\n", regs[2], regs[3], !!(regs[2] & (1<<28)), !!(regs[2] & (1<<26)), !!(regs[2] & (1<<27)));
    __cpuid(regs, 0x80000007);
    printf("invariant_tsc=%d\n", !!(regs[3] & (1 << 8)));
    printf("sink=%llu\n", sink & 1);
    return 0;
}

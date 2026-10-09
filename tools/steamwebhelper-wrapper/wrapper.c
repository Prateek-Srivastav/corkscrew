/* Stand-in for Steam's steamwebhelper.exe under Wine.
 *
 * Steam's Chromium (CEF 126) paints its windows black under Wine, and its separate network-service
 * process fails on Wine's winsock. Running the real helper in software, single-process mode avoids
 * both. This program starts steamwebhelper_real.exe from its own folder with the caller's
 * arguments plus those two switches, and returns its exit code. */
#include <windows.h>
#include <wchar.h>

#define EXTRA L" --disable-gpu --single-process"

/* Skips argv[0] in a Windows command line, honouring quotes. */
static const WCHAR *skip_program_name(const WCHAR *cmd)
{
    BOOL quoted = FALSE;
    for (; *cmd; cmd++)
    {
        if (*cmd == L'"') quoted = !quoted;
        else if (!quoted && (*cmd == L' ' || *cmd == L'\t')) break;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int wmain(void)
{
    WCHAR real[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, real, MAX_PATH);
    WCHAR *slash = wcsrchr(real, L'\\');
    if (!len || len >= MAX_PATH || !slash) return 1;
    wcscpy(slash + 1, L"steamwebhelper_real.exe");

    const WCHAR *args = skip_program_name(GetCommandLineW());
    size_t size = wcslen(real) + wcslen(args) + wcslen(EXTRA) + 8;
    WCHAR *cmdline = HeapAlloc(GetProcessHeap(), 0, size * sizeof(WCHAR));
    if (!cmdline) return 1;
    _snwprintf(cmdline, size, L"\"%ls\" %ls%ls", real, args, EXTRA);

    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(real, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return (int)GetLastError();
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
